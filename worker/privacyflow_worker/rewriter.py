"""Rewriting a transcript as finished written text, with S1-mini by Superwhisper.

The router answers "what kind of processing does this transcript need?". This
answers "what should it look like as written text?". S1-mini is a 0.6B
fine-tune of Qwen3-0.6B trained for exactly this one transformation. It is not
a chat model: it is steered by a control line at the top of its input, and the
system prompt and control line are the input format it was trained on.
Changing their wording, or sending values outside the trained sets, makes it
hallucinate, so both are a fixed contract rather than configuration.

8-bit, not 4-bit: measured over 53 real transcripts, 4-bit was 27% faster but
dropped speakers' self-corrections, which is the main reason to rewrite.
"""
from __future__ import annotations

import pathlib
import re
import time
from dataclasses import dataclass

# Required verbatim by the model card. Do not reword.
SYSTEM = (
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    "with a control line specifying the styling, structure, and context settings; "
    "clean the transcript to match those settings and output only the cleaned text."
)

# The model card's recommended general-purpose register. Styling and context
# are fixed; the router decides the structure per transcript.
STYLING = "semi-formal"
CONTEXT = "general"
STRUCTURES = ("prose", "lists")

# The spoken words and written symbols that entitle a rewrite to use each
# currency symbol. Only currencies S1-mini actually emits are listed.
CURRENCY_WORDS = {
    "$": ("dollar", "buck", "$"),
    "£": ("pound", "sterling", "quid", "£"),
    "€": ("euro", "€"),
    "¥": ("yen", "yuan", "¥"),
    "₹": ("rupee", "₹"),
}


@dataclass(frozen=True)
class Rewrite:
    """One rewritten transcript and what it cost to produce."""

    text: str
    latency_ms: float


def currency_contradiction(transcript: str, rewrite: str) -> list[str]:
    """Currency symbols in the rewrite that the transcript contradicts.

    S1-mini occasionally swaps one currency for another: "transfer forty seven
    thousand six hundred and twenty pounds to account ..." comes back as
    "Transfer $47,620 ...". It is deterministic but narrow, so it cannot be
    prompted away. A wrong amount pasted into a payment field is worse than no
    text, so the caller refuses such a rewrite.

    Only a changed currency counts. A symbol invented for an amount spoken
    without one is milder and far more common, and refusing it would cost more
    than it saves.
    """
    spoken = {symbol for symbol, words in CURRENCY_WORDS.items()
              if any(_mentions(transcript, word) for word in words)}
    if not spoken:
        return []
    return [symbol for symbol in CURRENCY_WORDS if symbol in rewrite and symbol not in spoken]


def _mentions(transcript: str, word: str) -> bool:
    """Whether the transcript names a currency by this word or symbol.

    Words match whole, optionally plural, so "european" is not a euro and
    "pounding" is not a pound. Symbols match anywhere.
    """
    if not word.isalpha():
        return word in transcript
    return re.search(rf"\b{word}s?\b", transcript, re.IGNORECASE) is not None


class Rewriter:
    """A resident S1-mini, loaded once from a local MLX build."""

    def __init__(self, model_dir: pathlib.Path) -> None:
        from mlx_lm.sample_utils import make_sampler
        from mlx_lm.tokenizer_utils import TokenizerWrapper
        from mlx_lm.utils import load_model
        from transformers import AutoTokenizer

        if not (model_dir / "config.json").is_file():
            raise RuntimeError(f"the S1-mini model is missing at {model_dir}")
        self.tokenizer = AutoTokenizer.from_pretrained(str(model_dir))
        self.model, _ = load_model(model_dir)
        self.tokenizer_wrapper = TokenizerWrapper(self.tokenizer)
        # The model was trained for greedy decoding.
        self.sampler = make_sampler(temp=0.0)

    def rewrite(self, transcript: str, structure: str) -> Rewrite:
        """Rewrite one transcript as finished text laid out as `structure`.

        An empty result is a legitimate model output for input that is nothing
        but filler, so it is returned as-is: whether it may be inserted is the
        caller's decision.
        """
        import mlx.core as mx
        from mlx_lm import generate

        if structure not in STRUCTURES:
            raise ValueError(f"structure must be one of {STRUCTURES}, got {structure!r}")
        control = f"[Styling: {STYLING}] [Structure: {structure}] [Context: {CONTEXT}]"
        prompt = self.tokenizer.apply_chat_template(
            [{"role": "system", "content": SYSTEM},
             {"role": "user", "content": f"{control}\n{transcript}"}],
            tokenize=False,
            add_generation_prompt=True,
            # Required. Without it the model opens a thinking block it never
            # closes and the decoded rewrite comes back blank.
            enable_thinking=False,
        )
        prompt_tokens = len(self.tokenizer.encode(prompt))

        started = time.perf_counter()
        text = generate(self.model, self.tokenizer_wrapper, prompt=prompt,
                        # The model card's budget for a rewrite of this input.
                        max_tokens=int(1.3 * prompt_tokens + 32),
                        sampler=self.sampler, verbose=False)
        mx.synchronize()
        return Rewrite(text=text.strip(), latency_ms=(time.perf_counter() - started) * 1000.0)

    def warm_up(self) -> None:
        """Run a throwaway rewrite so the next real one starts warm."""
        self.rewrite("hello there", structure="prose")

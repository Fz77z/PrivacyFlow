"""The router: decides what a transcript needs before it is inserted.

The router is Kev, a Qwen2.5-0.5B backbone with a merged LoRA adapter and a
pointer head. It reads the transcript once and answers two questions in the
same request: which route the text should take, and whether a rewrite should
lay it out as prose or as a list. Each answer is a probability distribution
over a fixed set of options, read from hidden states rather than generated.

Kev packs a request as the transcript followed by one branch per question.
Its attention mask is block causal: the transcript attends causally to
itself, and each question branch attends to the transcript and to itself,
never to a sibling question. Branch positions restart where the transcript
ends. That is exactly what running the transcript once and then each question
as a continuation of the transcript alone produces, so this module does that
with an ordinary key-value cache, rewinding it to the end of the transcript
before each question.

The question wording below is the input format the router was trained on.
Changing it changes every decision, so it is a fixed contract, not
configuration.
"""
from __future__ import annotations

import json
import math
import pathlib
import re
import time
from dataclasses import dataclass

# The four routes, in the order the router was trained to see them.
ROUTES = ("PASS_THROUGH", "LIGHT_CLEANUP", "TRANSFORM", "COMPLEX")
STRUCTURES = ("prose", "lists")

ROUTE_INSTRUCTIONS = (
    "The text above is a raw speech-to-text transcript of something a user just "
    "dictated. Which processing route should it take before the text is inserted "
    "at the user's cursor?"
)
ROUTE_CRITERIA = {
    "PASS_THROUGH": (
        "Insert the transcript unchanged. Nothing about it would embarrass the "
        "user if it appeared exactly as transcribed."
    ),
    "LIGHT_CLEANUP": (
        "Run a cheap deterministic pass that fixes punctuation, capitalization "
        "and filler words. The words themselves are already correct and stay in "
        "the same order."
    ),
    "TRANSFORM": (
        "Run a specialized rewriting model that must delete or reorder words the "
        "user actually said, because the user corrected themselves, restarted a "
        "sentence, repeated themselves, or spoke a formatting instruction aloud."
    ),
    "COMPLEX": (
        "Hand off to a large generative model that must understand the content "
        "and compose new text, because the user described what they want rather "
        "than dictating it."
    ),
}

STRUCTURE_INSTRUCTIONS = "Decide how the finished text should be laid out."
STRUCTURE_CRITERIA = {
    "prose": "Ordinary sentences and paragraphs.",
    "lists": "Two or more enumerated items the speaker counted off, such as "
             "first, second, third or one, two, three.",
}

# Kev reuses rarely used Qwen special tokens as its delimiters, in this order:
# transcript, question, option start, option end, decide.
STATE, QUESTION, OPTION_START, OPTION_END, DECIDE = DELIMITERS = (
    "<|fim_prefix|>", "<|fim_middle|>", "<|box_start|>", "<|box_end|>", "<|fim_suffix|>",
)

# Far above the training admission caps, which protected the experiment rather
# than the model: the backbone has a 32768 token context, and a minute of
# speech is about 400 tokens. Input beyond this is refused, never truncated
# into a decision about text the user never sees.
MAX_TOKENS = 8192

_SPECIAL = re.compile(r"<\|([A-Za-z0-9_]+)\|>")


@dataclass(frozen=True)
class Routing:
    """The router's two answers for one transcript."""

    route: str
    structure: str
    route_probabilities: dict[str, float]
    structure_probabilities: dict[str, float]
    latency_ms: float


@dataclass(frozen=True)
class _Branch:
    """One question's tokens, and where its readout positions sit within them."""

    ids: list[int]
    decide_index: int
    option_end_indices: list[int]


class Router:
    """A resident Kev router on MLX.

    Loads the converted model once. Each decision scores the hidden state at
    a question's decide token against the hidden state at each option's
    closing token with the pointer head, in fp32, and softmaxes over them.
    """

    def __init__(self, model_dir: pathlib.Path) -> None:
        import mlx.core as mx
        from mlx_lm.utils import load_model
        from transformers import AutoTokenizer

        metadata_path = model_dir / "kev.json"
        if not metadata_path.is_file():
            raise RuntimeError(f"the router model is missing its metadata: {metadata_path}")
        metadata = json.loads(metadata_path.read_text())
        # An option-isolated checkpoint needs a different mask than the cache
        # rewinding below reproduces, so it is refused rather than misread.
        if metadata["option_isolation"]:
            raise RuntimeError(f"{model_dir} was trained with option isolation, which this router does not reproduce")

        # Stated explicitly because transformers 4.57.6 suspects every local
        # tokenizer saved by 4.57.3 or later of carrying a Mistral regex bug
        # and warns at each load. This is Qwen's tokenizer, which has no such
        # bug, and the release gate holds its ids to Kev's exactly.
        self.tokenizer = AutoTokenizer.from_pretrained(str(model_dir), fix_mistral_regex=False)
        self.model, _ = load_model(model_dir)
        self.head = mx.load(str(model_dir / "head.safetensors"))
        self.scale = 1.0 / math.sqrt(metadata["head_dim"])
        mx.eval(self.model.parameters(), self.head)

        delimiter_ids = [self.tokenizer.convert_tokens_to_ids(token) for token in DELIMITERS]
        self.delimiter = dict(zip(DELIMITERS, delimiter_ids))
        # The questions never change, so they are tokenized once.
        self.route_branch = self._branch(ROUTE_INSTRUCTIONS, ROUTE_CRITERIA)
        self.structure_branch = self._branch(STRUCTURE_INSTRUCTIONS, STRUCTURE_CRITERIA)

    def route(self, transcript: str) -> Routing:
        """Answer both questions about one transcript."""
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        started = time.perf_counter()
        state = [self.delimiter[STATE]] + self._user_tokens(transcript)
        branches = (self.route_branch, self.structure_branch)
        longest = max(len(branch.ids) for branch in branches)
        if len(state) + longest > MAX_TOKENS:
            raise ValueError(f"the transcript is too long for the router: {len(state)} tokens")

        cache = make_prompt_cache(self.model)
        self.model.model(mx.array(state)[None], cache=cache)
        distributions = []
        for branch in branches:
            hidden = self.model.model(mx.array(branch.ids)[None], cache=cache)[0]
            distributions.append(self._pointer(hidden.astype(mx.float32), branch))
            # Rewinding to the end of the transcript is what keeps the next
            # question from seeing this one, as Kev's block-causal mask does.
            for layer_cache in cache:
                layer_cache.trim(len(branch.ids))
        mx.eval(distributions)
        latency_ms = (time.perf_counter() - started) * 1000.0

        route_probabilities = dict(zip(ROUTE_CRITERIA, distributions[0].tolist()))
        structure_probabilities = dict(zip(STRUCTURE_CRITERIA, distributions[1].tolist()))
        return Routing(
            route=max(route_probabilities, key=route_probabilities.__getitem__),
            structure=max(structure_probabilities, key=structure_probabilities.__getitem__),
            route_probabilities=route_probabilities,
            structure_probabilities=structure_probabilities,
            latency_ms=latency_ms,
        )

    def _pointer(self, hidden, branch: _Branch):
        """One question's distribution over its options, from the pointer head."""
        import mlx.core as mx

        query = hidden[branch.decide_index] @ self.head["q.weight"].T + self.head["q.bias"]
        keys = hidden[mx.array(branch.option_end_indices)] @ self.head["k.weight"].T + self.head["k.bias"]
        return mx.softmax((keys @ query) * self.scale)

    def _branch(self, instructions: str, criteria: dict[str, str]) -> _Branch:
        """Pack one question as Kev does: question, each option, then decide.

        Each option is read at its closing delimiter, the last token of its span.
        """
        ids = [self.delimiter[QUESTION]] + self._user_tokens(instructions)
        option_end_indices = []
        for name, description in criteria.items():
            ids += [self.delimiter[OPTION_START]] + self._user_tokens(f"{name}: {description}")
            ids.append(self.delimiter[OPTION_END])
            option_end_indices.append(len(ids) - 1)
        ids.append(self.delimiter[DECIDE])
        return _Branch(ids=ids, decide_index=len(ids) - 1, option_end_indices=option_end_indices)

    def _user_tokens(self, text: str) -> list[int]:
        """Tokenize text so it can never produce one of Kev's delimiter tokens.

        The fast tokenizer ignores split_special_tokens, so `<|name|>` is
        rewritten to `<¦name¦>` first, exactly as Kev does in training.
        """
        return self.tokenizer(_SPECIAL.sub(r"<¦\1¦>", text), add_special_tokens=False).input_ids

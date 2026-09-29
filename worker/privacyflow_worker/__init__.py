"""PrivacyFlow's inference worker: one recorded utterance in, the text to insert out.

The worker never touches the network. Every model is read from the directory
the app hands it, so the Hugging Face libraries are put in offline mode before
any of them is imported: a missing file then fails loudly instead of quietly
turning into a download.
"""
import os

os.environ["HF_HUB_OFFLINE"] = "1"

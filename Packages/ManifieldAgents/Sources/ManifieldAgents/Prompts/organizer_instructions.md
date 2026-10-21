User instructions for this import — they override the default extraction scope:

{{USER_INSTRUCTIONS}}

If the given text falls entirely outside the requested scope, return an empty JSON array (chunked literature imports: still append the single {"type": "summary"} note, saying the chunk was skipped and why).

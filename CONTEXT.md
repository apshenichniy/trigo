# Trigo

Trigo is a personal call archive. It captures conversations, preserves their transcripts, and provides evidence for the user's chosen assistant to interpret.

## Language

**Call**:
A conversation captured as one recording session, including one-to-one and group conversations.

**Capture source**:
The application selected for recording through one of its windows. Selecting a window identifies the application; it does not imply that its audio is isolated from other windows or tabs of that application.

**Audio track**:
A recording of one audio source, such as the local microphone or the selected application's output. A track can contain more than one person's voice.
_Avoid_: Speaker channel

**Transcript**:
The recorded speech represented as text with time positions and speaker labels where available. A transcript can be useful even when speaker attribution is incomplete.

**Turn**:
A time-bounded passage of a transcript associated with a speaker label when one is available.
_Avoid_: Message

**Speaker**:
A voice distinguished within a call. A speaker label does not by itself establish the person's identity.

**Participant**:
A person taking part in a call. Identifying a participant and attributing particular turns to that person are separate claims.

**Canonical call document**:
The authoritative record of a call's transcript and associated metadata, from which search representations can be rebuilt.
_Avoid_: Search document

**Corpus**:
The collection of retained calls available for retrieval.

**Evidence**:
A verbatim transcript passage or recorded metadata returned for an assistant to interpret. Evidence contains no product-generated conclusions about what was discussed.

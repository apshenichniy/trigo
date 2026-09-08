# Trigo

Trigo is a personal call archive. It captures conversations, preserves their transcripts, and provides evidence for the user's chosen assistant to interpret.

## Language

**Call**:
A single recording session of a conversation from one fixed capture source, including one-to-one and group conversations. A conversation recorded across different capture sources produces separate calls.

**Capture source**:
The application selected for recording through one of its windows. Selecting a window identifies the application; it does not imply that its audio is isolated from other windows or tabs of that application.

**Audio track**:
A recording of one audio source, such as the local microphone or the selected application's output. A track can contain more than one person's voice.
_Avoid_: Speaker channel

**Recording master**:
The complete recorded audio for one call, retaining microphone and application contributions on separate channels. Transport parts and transcription inputs are derived from this master without changing its identity.

**Confirmed media progress**:
The verified portion of a recording master that has become durable and may be read during recording. It does not establish that the whole call has reached the server.

**Verified server storage receipt**:
Evidence that the complete recording master is stored and verified by the server. Durably recording that receipt locally authorizes removal of the temporary local audio.

**Microphone recording mute**:
A state in which Trigo excludes microphone input from a call's recording while retaining the capture source's audio. It is independent of microphone mute in the calling application.

**Transcript**:
The recorded speech represented as text with time positions and speaker labels where available. A transcript can be useful even when speaker attribution is incomplete.

**Transcript revision**:
A retained version of a call's transcript, including the names assigned to its speaker labels. Re-transcribing a call produces a new revision while previous revisions remain available.

**Turn**:
A time-bounded passage of a transcript associated with a speaker label when one is available.
_Avoid_: Message

**Speaker**:
A voice distinguished within a call. A speaker label does not by itself establish the person's identity.

**Speaker group**:
An owner-authored grouping of existing speaker labels within one transcript revision, with a shared display name. It records the owner's attribution without changing the original transcript evidence or establishing participant identity.

**Participant**:
A person taking part in a call. Identifying a participant and attributing particular turns to that person are separate claims.

**Canonical call document**:
The authoritative record of a call's transcript revisions and associated metadata, from which search representations can be rebuilt. A published exchange snapshot is one retained version of that record, not an independently mutable copy.
_Avoid_: Search document

**Call lifecycle**:
The independent capture, upload, transcription, local import, replica and deletion states of a call. Success in one dimension does not imply completion of the others.

**Corpus**:
The collection of retained calls available for retrieval.

**Evidence**:
A verbatim transcript passage or recorded metadata returned for an assistant to interpret. Evidence contains no product-generated conclusions about what was discussed.

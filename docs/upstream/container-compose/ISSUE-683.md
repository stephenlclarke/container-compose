# Issue 683: fail fast when the selected Xcode licence is unaccepted

Unattended maintenance release run [34912847740](https://github.com/stephenlclarke/container-compose/actions/runs/34912847740) entered the live sibling-stack gate and spent 2,201.100 seconds validating the enhanced Container stack. Enhanced Container documentation completed, but the following build failed with exit 69 because the selected `/Applications/Xcode.app` licence had not been accepted.

The release bootstrap validated repository authority, storage ownership, signing configuration, and runtime prerequisites, but it did not verify the selected Xcode installation before creating the retained transaction and starting expensive validation. A release host updated to a new Xcode could therefore waste more than half an hour before reporting a one-time host setup requirement.

An executable release must run `xcodebuild -license check` before entering the isolated transaction. Missing Xcode and an unaccepted licence must fail with exit 69 and a clear remediation message. The controller must never accept Apple's agreement automatically and must never open an interactive password or licence prompt.

Regression coverage must prove the accepted, unaccepted, and missing-tool paths and verify that the check precedes isolated release execution.

Related issue: [#683](https://github.com/stephenlclarke/container-compose/issues/683).

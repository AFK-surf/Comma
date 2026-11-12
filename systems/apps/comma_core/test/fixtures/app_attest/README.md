# Apple assertion fixture

`ios-14.4-assertion.json` contains the assertion sample from
[veehaitch/devicecheck-appattest, commit cb26211f63c1e2e7949deafe2efdf352daca27fa](https://github.com/veehaitch/devicecheck-appattest/blob/cb26211f63c1e2e7949deafe2efdf352daca27fa/src/test/resources/ios-14.4.yaml).
Sample ID: `c5051b6a-7f30-8d79-012a-f46d5de83193`. Its public key and client data remain unchanged.
The source identifies this as an iOS 14.4 assertion. The adjacent `LICENSE` preserves its Apache-2.0 license.

This fixed device signature checks the production verifier's message-versus-digest convention independently of generated test signatures.
Copies in other verifier libraries are the same vector, not independent evidence.

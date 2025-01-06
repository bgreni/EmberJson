# Contributing to EmberJson

Thank you for considering contributing to EmberJson! To help you get started and to keep things running smoothly please refer to this guide before you being contributing.

## Ways to contribute

### Submitting bugs

Please report any incorrect or unexpected behaviour in the form of a bug ticket. Please include code snippet reproducing the noted behaviour, as well any JSON input required to reproduce the issue.

### Contributing to docs and examples

Any pull requests improving documentation, or more usage examples are welcome. Including function/method documentation.

### Features and optimizations

EmberJson is still under heavy development, so I'm not against doing any drastic changes to the interfaces,
but I would recommend making a proposal first so you don't waste your time implementing changes that aren't going to be accepted.

EmberJson aims to be a relatively fast JSON implementation so any effort to improve
performance will be most welcome. Arcane sorcery is acceptable but MUST be throughouly documented
for future reference and understanding.

### Making a pull request

Once your changes are ready. Be sure to run `magic run test`
to run all the unit tests, run `magic run bench` before and after you changes to ensure you haven't introduced any major performance regressions, and `magic run format` to format your code before making a PR.

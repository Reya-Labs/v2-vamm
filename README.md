# Prerequistes

- Node v18 and `yarn`/`pnpm`
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Run `yarn` to install dependencies

# Testing

`forge test -vvv`

Install [foundry](https://book.getfoundry.sh/getting-started/installation) and run:

# Deployment

TODO.

# Open issues

- Testing is very much a work in progress. _Lots_ still to test.
  - In particular, I (Cyclops) have low confidence that toekn tracking functions such as `trackFixedTokens` are doing the correct thing.
- Need to add the concept of spread to all trades, so that LPs take the spread. (Safest to do this alongside relevant tests.)
- At the moment, the code is structured such that we can have many different DatedIrsVammPool instances, each with their own ID. Should we just have one singleton DatedIrsVammPool?
- Deployment logic is non-existent
- We need to integrate with the `v2-core` repo, and in doing so we will presumably discover some API incompatibilities.
- Authorisation of many non-view functions is absent. Need a clear design and implementation here. msg.sender will probably not be the end user, but one of our contracts.
- (how/when) are old positions removed from the positions list, to speed up future operations?
- Measure code coverage, gas usage etc.
- Linting, formatting, git hooks and CI config, etc.

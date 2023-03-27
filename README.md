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
- Deployment logic is non-existent
- We need to integrate with the `v2-core` repo, and in doing so we will presumably discover some API incompatibilities.
- Authorisation of many non-view functions is absent. Need a clear design and implementation here. msg.sender will probably not be the end user, but one of our contracts.
- (how/when) are old positions removed from the positions list, to speed up future operations?
- Measure code coverage, gas usage etc.
- Linting, formatting, git hooks and CI config, etc.

# Testing plan

Continue with docs and tests of low-level functions in isolation, and work up to higher functions that call them.

Docs will act as a sanity check that I'm testing the right thing.

- flipTicks?
- trackFixedTokens
- trackValuesBetweenTicks
- calculateUpdatedGlobalTrackerValues
- getAccountUnfilledBases
- getAccountFilledBases
- trackValuesBetweenTicksOutside
- growthBetweenTicks

Fix issues found.

Once we have tests, we can refactor some of the above to be more efficient. E.g. remove substantial re-fetching of the same data within a swap's tick iteration loop.

Then move on to higher level functions:

- vammMint
- vammSwap

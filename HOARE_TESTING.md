# Hoare Test Contracts

Every automated behavior test states one executable Hoare triple:

```text
P: the precondition established by fixtures and setup
C: the command or transition under test
Q: the postcondition asserted by the test
```

ExUnit names use `P[...] C[...] Q[...]`. Rust test functions use
`p_..._c_..._q_...`. The contract name is not the proof by itself: setup must
establish P, the body must execute C, and assertions must verify Q, including
unchanged-state and cleanup claims on errors.

`test/hoare_contract_test.exs` rejects automated tests that omit the contract.
Helpers, fixtures, and the manual `test_libp2p.exs` smoke script are not tests
and are outside this naming rule.

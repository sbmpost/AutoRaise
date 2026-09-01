GUI changes (menu bar, preferences, app bundle, login item) belong in
[AutoRaise-UI](https://github.com/sbmpost/AutoRaise-UI), not here.

**What this changes**

<!-- One sentence. -->

**Checklist**

- [ ] Rebased on current master
- [ ] One behaviour change, no refactor bundled in
- [ ] No existing check removed or weakened as a side effect
- [ ] New options default to off, existing defaults unchanged
- [ ] Core logic: ___ lines (excluding comments, tests and documentation)

AutoRaise is meant to stay small. A fix that needs a lot of code to explain
itself is usually solving the problem in the wrong place.

# Publishing checklist

A practical checklist for getting this repo into a clean public GitHub state.

## Repo surface

- [ ] Root `README.md` accurately describes the package map
- [ ] Package READMEs are internally consistent
- [ ] Experimental areas are labeled clearly (`vpty`, `alt`)
- [ ] Legacy code and dead packages are removed from the active build graph
- [ ] No machine-local secrets, tokens, or private notes remain in tracked files

## Build and test

- [ ] `zig build` passes from a clean clone
- [ ] `zig build test` passes from a clean clone
- [ ] Shell scripts pass syntax checks
- [ ] Key smoke scripts are documented

## Docs

- [ ] Root README explains how `msr`, `dsm`, `wsm`, `vpty`, and `alt` fit together
- [ ] Each package README answers what it is, why it exists, and how stable it is
- [ ] A short quickstart exists for the main runtime path
- [ ] Known rough edges are documented honestly

## GitHub readiness

- [ ] CI runs build and test on push/PR
- [ ] License is present
- [ ] Issue templates exist
- [ ] Contribution guidance exists
- [ ] First public release posture is explicitly marked experimental/alpha

## Suggested release posture

Publish early, but honestly:

- core runtime and session-management story documented
- terminal/rendering and switcher layers marked experimental where appropriate
- avoid pretending the project is more stable than it is

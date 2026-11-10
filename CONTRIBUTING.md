# Contributing to SousSight

Thanks for helping. Read [AGENTS.md](AGENTS.md) for the working agreement and [README.md](README.md) for running and testing the app.

## License of contributions

SousSight is licensed under the [GNU Affero General Public License v3.0](LICENSE). By contributing, you agree that your contribution is licensed under the same terms.

## Sign your commits (DCO)

Every commit must include a `Signed-off-by` line certifying the [Developer Certificate of Origin 1.1](https://developercertificate.org/): that you wrote the change, or otherwise have the right to submit it under this project's license.

```sh
git commit -s -m "Describe the change"
```

This adds `Signed-off-by: Your Name <you@example.com>` using your Git identity.

## Pull requests

- Use a branch per change and stack dependent pull requests.
- Run the checks in the README's **Test** section before you open a pull request.
- Keep credentials out of Git and out of browser bundles.
- Label simulated behavior as simulated, and don't claim a live service was tested when only fakes or static checks ran.

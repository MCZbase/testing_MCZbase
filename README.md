# testing_MCZbase
Tools for testing MCZbase behavior.

## checkPages.sh

Checks an MCZbase server from outside, as a visitor would: routes and redirects, session handling,
pages refused to visitors, the pages a visitor may open and the files they load, the legacy specimen
search, the project search and its backing methods, and the `/guid/`, `/name/`, `/media/` and other record routes.  With `-b` it also opens pages in
headless Chromium and reports script errors and failed requests; with a logged-in session cookie in
`MCZ_COOKIE` it opens staff pages too.  With `-x` it also checks the accessibility of a few redesigned
pages, with axe-core (WCAG 2.1 A and AA) and the MCZbase developer guide's own rules; legacy pages are
left out, as they are being replaced.  `./checkPages.sh -h` describes the options.

Needs bash, curl and perl; `-b` and `-x` also need chromium and node (no packages).

`vendor/axe-core-4.13.0/` holds axe-core's `axe.min.js` from the npm release, checked against the
registry's integrity hash when added, with its license (MPL-2.0).  The script checks the file's
SHA-256 before running it; update the hash in `checkPages.sh` when updating axe-core.

```
# a test server with a self-signed certificate
./checkPages.sh -k -i test.ids https://test-server.example.edu/
# production, with its Apache redirects and the browser checks
./checkPages.sh -a -b -i production.ids https://production-server.example.edu/
```

Record identifiers that can't be looked up anonymously go in a `*.ids` file (see `example.ids`), which
git ignores: one of them names a record that isn't public.

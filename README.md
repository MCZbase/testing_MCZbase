# testing_MCZbase
Tools for testing MCZbase behavior.

## checkPages.sh

Checks an MCZbase server from outside, as a visitor would: routes and redirects, session handling,
pages refused to visitors, the pages a visitor may open and the files they load, the legacy specimen
search, and the `/guid/`, `/name/`, `/media/` and other record routes.  With `-b` it also opens pages in
headless Chromium and reports script errors and failed requests; with a logged-in session cookie in
`MCZ_COOKIE` it opens staff pages too.  The usage and options are described at the top of the script.

Needs bash, curl and perl; `-b` also needs chromium and node (no packages).

```
# a test server with a self-signed certificate
./checkPages.sh -k -i test.ids https://test-server.example.edu/
# production, with its Apache redirects and the browser checks
./checkPages.sh -a -b -i production.ids https://production-server.example.edu/
```

Record identifiers that can't be looked up anonymously go in a `*.ids` file (see `example.ids`), which
git ignores: one of them names a record that isn't public.

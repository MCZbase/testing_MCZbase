#!/usr/bin/env bash
# checkPages.sh exercises MCZbase routes, session handling and pages with curl, and optionally a
# headless browser, and reports PASS, FAIL or SKIP for each check: HTTP status, Location, number of
# CFID cookies set (sessions started), and page content.
#
# Copyright 2026 President and Fellows of Harvard College
# Licensed under the Apache License, Version 2.0; see LICENSE.
#
# Usage: ./checkPages.sh [-h] [-k] [-i file] [-s] [-a] [-b] [-x] https://host
#   -k  accept a certificate that can't be verified, as for a test server with a self-signed one.
#       Without it, certificates are verified.
#   -i  read record identifiers (see below) from a file of NAME=value lines.
#   -s  also run the slow checks, which wait 7 minutes for an unused session to expire.
#   -a  production: also check the old page redirects made by production's Apache rewrite rules
#       (SpecimenDetail.cfm, MediaSet.cfm and the like).
#   -b  also open pages in headless Chromium (driven by node over --remote-debugging-pipe, no packages
#       needed) and fail on uncaught script errors, console.error, security errors and failed requests
#       to the site.  With MCZ_COOKIE set to a logged-in browser's "CFID=...; CFTOKEN=..." (from its
#       developer tools), staff pages are opened too.  The cookie goes only to the site, and only to
#       the node checker, never on a command line.  Use it only with certificate checking on (no -k)
#       unless the network to the server is trusted.
#   -x  with the browser checks (implies -b), also check the accessibility of a few redesigned pages
#       (ACCESSIBILITY_PAGES below; legacy pages are left out, as they are being replaced): axe-core
#       (vendor/, checked against its hash before use) for WCAG 2.1 A and AA, and the MCZbase developer
#       guide's own rules (one <main id="content">, no role="main" on main or role="region" on
#       section, headings starting at h1 without skipping levels, and no more than one accessible name
#       on an input).  Issues are listed per page and summarized by rule, as A11Y lines; they don't
#       count as failures.
#
# Record identifiers: routes that need a real record take its identifier from the environment, then
# from the -i file, or else look one up with the public searches the site's own pages use (the
# specimen, taxon, publication, project, named group and media autocompletes, and the document list).
# Lookups can override: CATNUM (an MCZ:Mamm catalog number), COLL_OBJECT_ID, TAXON_NAME, TAXON_NAME_ID,
# MEDIA_ID, PUBLICATION_ID, PROJECT_NAME, NAMED_GROUP, DOCUMENT (the part of a /document/ url after
# /document/).  These can't be looked up anonymously, so their checks are skipped unless set:
#   UUID          a guid_our_thing.local_identifier with guid_is_a occurrenceID
#   SAVED_SEARCH  a cf_canned_search.search_name
#   HIDDEN_GUID   the guid of a cataloged item that exists but that an anonymous user may not see
# Keep identifier files out of this repository (*.ids is ignored): HIDDEN_GUID names a record that
# isn't public.  example.ids shows the format.
#
# Library versions: the checks expect the jQuery, jQuery UI and Bootstrap versions below on every
# page; set JQUERY_FILE, JQUERY_UI_DIR and BOOTSTRAP_DIR to check a server running other versions.
#
# Requests identify themselves as MCZbaseTestHarness followed by the first 10 characters of this
# repository's commit, so they can be told apart in the server's logs.  curl sends it as the user
# agent; Chromium adds it to its own, so pages still treat it as a browser.
#
# Scheduled tasks are not requested: if a refusal failed, the task would run.
#
# The exit status is the number of failed checks, at most 255.

SLOW=0
APACHE=0
BROWSER=0
ACCESSIBILITY=0
INSECURE=0
IDENTIFIER_FILE=""
# usage prints how to run this script and what each option does.
usage() {
	cat <<USAGE
Usage: $0 [-h] [-k] [-i file] [-s] [-a] [-b] [-x] https://host

Checks an MCZbase server as a visitor would.  Exit status: the number of failures.

  -h       Show this help.
  -k       Accept a self-signed certificate.
  -i file  Read record identifiers from a file of NAME=value lines (see example.ids).
  -s       Also run the slow session-expiry checks (7 minutes).
  -a       Also check production's Apache redirects of old pages.
  -b       Also open pages in headless Chromium and fail on errors (needs chromium, node).
           Set MCZ_COOKIE="CFID=...; CFTOKEN=..." to include staff pages.
  -x       As -b, plus accessibility checks (reported, not counted as failures).

Examples:
  $0 -k -i test.ids https://test-server.example.edu/
  $0 -a -b -i production.ids https://production-server.example.edu/
USAGE
}
while [[ "$1" == -* ]]; do
	case "$1" in
		-h) usage; exit 0 ;;
		-k) INSECURE=1 ;;
		-i) IDENTIFIER_FILE="$2"; shift ;;
		-s) SLOW=1 ;;
		-a) APACHE=1 ;;
		-b) BROWSER=1 ;;
		-x) BROWSER=1; ACCESSIBILITY=1 ;;
		*) echo "Unknown option $1" >&2; usage >&2; exit 255 ;;
	esac
	shift
done
HOST="${1%/}"
if [[ ! "$HOST" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
	usage >&2
	exit 255
fi

# IDENTIFIER_NAMES are the only names an identifier file may set; one already in the environment wins.
IDENTIFIER_NAMES="CATNUM COLL_OBJECT_ID TAXON_NAME TAXON_NAME_ID PUBLICATION_ID PROJECT_NAME NAMED_GROUP MEDIA_ID DOCUMENT UUID SAVED_SEARCH HIDDEN_GUID"
if [ -n "$IDENTIFIER_FILE" ]; then
	if [ ! -r "$IDENTIFIER_FILE" ]; then
		echo "Can't read $IDENTIFIER_FILE" >&2
		exit 255
	fi
	# read as data, not sourced, so the file can't run commands
	while IFS='=' read -r name value; do
		if [[ " $IDENTIFIER_NAMES " == *" $name "* ]] && [ -z "${!name}" ]; then
			printf -v "$name" '%s' "$value"
		fi
	done < <(grep -E '^[A-Z_]+=' "$IDENTIFIER_FILE")
fi

JQUERY_FILE="${JQUERY_FILE:-/lib/jquery/jquery-3.7.1.min.js}"
JQUERY_UI_DIR="${JQUERY_UI_DIR:-/lib/jquery-ui-1.14.1/}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/lib/bootstrap/bootstrap-4.6.2-dist/}"
# libraries no page should load any longer
OLD_LIBRARIES="jquery-3\\.5\\.1|jquery-ui-1\\.12\\.1|bootstrap-4\\.5\\.0|jquery-migrate|knockout|multizoom"

HARNESS_COMMIT=$(git -C "$(dirname "$0")" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)
USER_AGENT="MCZbaseTestHarness$HARNESS_COMMIT"
# later -A options, such as the health check's, take precedence over this one
CURL_OPTIONS=(-A "$USER_AGENT")
if [ "$INSECURE" = "1" ]; then
	CURL_OPTIONS+=(-k)
fi
if ! curl -s "${CURL_OPTIONS[@]}" --max-time 30 -o /dev/null "$HOST/"; then
	echo "Can't reach $HOST (for a server with a self-signed certificate, add -k)" >&2
	exit 255
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASSED=0
FAILED=0
SKIPPED=0
ERROR_PAGE="An error occurred while processing this page"

# fetch requests a url, recording status, Location, content type and CFID cookie count.
# @param $1 the url; any further arguments are passed to curl.
fetch() {
	local url="$1"
	shift
	: > "$WORK/headers"
	: > "$WORK/body"
	STATUS=$(curl -s "${CURL_OPTIONS[@]}" --max-time 90 -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}' "$@" "$url")
	LOCATION=$(grep -i '^location:' "$WORK/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')
	CONTENT_TYPE=$(grep -i '^content-type:' "$WORK/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')
	CFIDS=$(grep -ic '^set-cookie: CFID=' "$WORK/headers")
	CFID_VALUE=$(grep -i '^set-cookie: CFID=' "$WORK/headers" | tail -1 | sed -E 's/^[^=]*=([^;]*).*/\1/' | tr -d '\r')
	CFTOKEN_VALUE=$(grep -i '^set-cookie: CFTOKEN=' "$WORK/headers" | tail -1 | sed -E 's/^[^=]*=([^;]*).*/\1/' | tr -d '\r')
	COOKIES=$(grep -ic '^set-cookie:' "$WORK/headers")
}

# check requests a path and compares the response with what is expected.
# @param $1 description.
# @param $2 path, or a full url when it starts with http.
# @param $3 expected status codes, separated by |.
# @param $4 expected number of CFID cookies, or - not to check.
# @param $5 regular expression the Location must match, or - for no Location.
# @param $6 regular expression the body must match, or - not to check.
# @param $7 allowerror to accept MCZbase's error page in the body (refusals use it).
# Further arguments are passed to curl.
check() {
	local description="$1" path="$2" statuses="$3" cfids="$4" location="$5" content="$6" allow="$7"
	shift 7
	local url="$HOST$path"
	if [[ "$path" == http* ]]; then
		url="$path"
	fi
	fetch "$url" "$@"
	local problems=""
	if ! [[ "|$statuses|" == *"|$STATUS|"* ]]; then
		problems+=" status $STATUS, expected $statuses;"
	fi
	if [ "$cfids" != "-" ] && [ "$CFIDS" != "$cfids" ]; then
		problems+=" $CFIDS CFID cookies, expected $cfids;"
	fi
	if [ "$location" = "-" ]; then
		if [ -n "$LOCATION" ]; then
			problems+=" unexpected Location $LOCATION;"
		fi
	elif ! [[ "$LOCATION" =~ $location ]]; then
		problems+=" Location [$LOCATION] doesn't match $location;"
	fi
	if [ "$content" != "-" ] && ! grep -Eq "$content" "$WORK/body"; then
		problems+=" body doesn't match /$content/;"
	fi
	if [ "$allow" != "allowerror" ] && grep -q "$ERROR_PAGE" "$WORK/body"; then
		problems+=" body is MCZbase's error page;"
	fi
	if [ -z "$problems" ]; then
		PASSED=$((PASSED + 1))
		printf 'PASS  %-58s %s cfid=%s\n' "$description" "$STATUS" "$CFIDS"
	else
		FAILED=$((FAILED + 1))
		printf 'FAIL  %-58s %s cfid=%s:%s\n' "$description" "$STATUS" "$CFIDS" "$problems"
		printf '      %s\n' "$url"
	fi
}

# fail records a failed check that isn't a single request.
# @param $1 the message.
fail() {
	FAILED=$((FAILED + 1))
	echo "FAIL  $1"
}

# skip reports a check that can't run without an identifier.
# @param $1 description.
# @param $2 what to set.
skip() {
	SKIPPED=$((SKIPPED + 1))
	printf 'SKIP  %-58s set %s\n' "$1" "$2"
}

# urlEncode percent-encodes a value for a path segment or query parameter.
# @param $1 the value.
urlEncode() {
	local value="$1" encoded="" i c
	for ((i = 0; i < ${#value}; i++)); do
		c="${value:i:1}"
		case "$c" in
			[a-zA-Z0-9.~_:-]) encoded+="$c" ;;
			*) encoded+=$(printf '%%%02X' "'$c") ;;
		esac
	done
	printf '%s' "$encoded"
}

# jsonField prints the first value of a field in a json response, quoted or not.
# @param $1 field name.
# @param $2 file holding the response.
jsonField() {
	grep -oiE "\"$1\" *: *(\"[^\"]*\"|[0-9]+)" "$2" | head -1 | sed -E 's/^[^:]*: *"?//; s/"$//'
}

# lookUp requests a public search method and saves the response body.
# @param $1 path and query string.
lookUp() {
	curl -s "${CURL_OPTIONS[@]}" --max-time 60 "$HOST$1" > "$WORK/lookup"
}

# requireNumber clears an identifier that isn't a whole number, as one from a lookup response might be.
# @param $1 the variable's name.
requireNumber() {
	if [ -n "${!1}" ] && [[ ! "${!1}" =~ ^[0-9]+$ ]]; then
		echo "      ignoring $1 [${!1}]: not a number"
		printf -v "$1" '%s' ""
	fi
}

echo "== Requests identified as $USER_AGENT"
echo "== Looking up identifiers"
if [ -z "$CATNUM" ] || [ -z "$COLL_OBJECT_ID" ]; then
	lookUp "/specimens/component/search.cfc?method=getCatalogedItemAutocompleteMeta&term=MCZ:Mamm:"
	FOUND_GUID=$(jsonField value "$WORK/lookup")
	if [[ "$FOUND_GUID" == MCZ:Mamm:* ]]; then
		CATNUM="${CATNUM:-${FOUND_GUID##*:}}"
		COLL_OBJECT_ID="${COLL_OBJECT_ID:-$(jsonField id "$WORK/lookup")}"
	fi
fi
if [ -z "$TAXON_NAME" ] || [ -z "$TAXON_NAME_ID" ]; then
	lookUp "/taxonomy/component/search.cfc?method=getScientificNameAutocomplete&term=Canis%20lupus&include_authorship=false"
	TAXON_NAME="${TAXON_NAME:-$(jsonField value "$WORK/lookup")}"
	TAXON_NAME_ID="${TAXON_NAME_ID:-$(jsonField id "$WORK/lookup")}"
fi
if [ -z "$PUBLICATION_ID" ]; then
	lookUp "/publications/component/search.cfc?method=getPublicationAutocompleteMeta&term=Bulletin"
	PUBLICATION_ID=$(jsonField id "$WORK/lookup")
fi
if [ -z "$PROJECT_NAME" ]; then
	# /project/ takes the name with spaces as dashes, matched exactly, so one of only letters and spaces
	lookUp "/projects/component/search.cfc?method=getProjectAutocompleteMeta&term=a"
	PROJECT_NAME=$(grep -oE '"value" *: *"[A-Za-z ]+"' "$WORK/lookup" | head -1 | sed -E 's/^[^:]*: *"//; s/"$//')
fi
if [ -z "$NAMED_GROUP" ]; then
	# /namedGroup/ takes the link name or the id
	lookUp "/grouping/component/search.cfc?method=getNamedCollectionAutocomplete&term=a"
	NAMED_GROUP=$(jsonField id "$WORK/lookup")
fi
if [ -z "$MEDIA_ID" ]; then
	lookUp "/media/component/search.cfc?method=getMediaAutocomplete&term=.jpg"
	MEDIA_ID=$(jsonField id "$WORK/lookup")
fi
if [ -z "$DOCUMENT" ]; then
	# the document list's first title, and the /document/ path its search redirects to
	lookUp "/document.cfm"
	DOCUMENT_TITLE=$(grep -oE '<option value="[^"]+"' "$WORK/lookup" | head -1 | sed -E 's/^<option value="//; s/"$//')
	if [ -n "$DOCUMENT_TITLE" ]; then
		fetch "$HOST/document.cfm?action=srchResult&mtitle=$(urlEncode "$DOCUMENT_TITLE")"
		if [[ "$LOCATION" == */document/* ]]; then
			DOCUMENT="${LOCATION##*/document/}"
		fi
	fi
fi
for name in CATNUM COLL_OBJECT_ID TAXON_NAME_ID PUBLICATION_ID MEDIA_ID; do
	requireNumber "$name"
done
for name in $IDENTIFIER_NAMES; do
	value="${!name:-(none)}"
	if [ "$name" = "HIDDEN_GUID" ] && [ -n "${!name}" ]; then
		value="(set)"
	fi
	printf '      %-15s %s\n' "$name" "$value"
done

echo "== Load balancer health check: no session, no cookies, no page"
check "health check answered OK" "/" "200" "0" "-" "^OK" "" -A "ELB-HealthChecker/2.0"
if [ "$COOKIES" != "0" ]; then
	fail "health check set $COOKIES cookies, expected none"
fi
if [ "$STATUS" = "200" ] && [ "$(tr -d '[:space:]' < "$WORK/body")" != "OK" ]; then
	fail "health check body is more than OK, so a page ran"
fi
check "health check user agent on another page" "/Specimens.cfm" "200" "0" "-" "^OK" "" -A "ELB-HealthChecker/2.0"
check "health check user agent on /guid/" "/guid/MCZ:Mamm:1" "200" "0" "-" "^OK" "" -A "ELB-HealthChecker/2.0"

echo "== Static files: served without ColdFusion, no session"
check "stylesheet" "/shared/css/custom_styles.css" "200" "0" "-" "-" ""
check "image" "/shared/images/48px-Gnome-image-x-generic.svg.png" "200" "0" "-" "-" ""

echo "== Pages that only forward: one session each"
check "/ forwards to the specimen search" "/" "200" "1" "-" "-" ""
for directory in /agents/ /media/ /specimens/ /transactions/ /localities/ /vocabularies/ /users/ /metrics/ \
		/metrics/datafiles/ /dataquality/ /shared/images/; do
	check "$directory forwards to its search page" "$directory" "200" "1" "-" "-" ""
done
check "/index.cfm named" "/index.cfm" "200" "1" "-" "-" ""
check "/Specimens.cfm directly" "/Specimens.cfm" "200" "1" "-" "-" ""
check "/login.cfm" "/login.cfm" "200" "1" "-" "-" ""
check "anonymous profile page redirects to login" "/users/UserProfile.cfm" "302" "1" "/login.cfm" "-" ""
check "AJAX method without a cookie" "/vocabularies/component/search.cfc?method=getJournalAutocomplete&term=Journal" "200" "1" "-" "-" ""
# the &amp; correction forwards to the same page, so a client without cookies gets a second session: not counted
check "&amp; in the query string is corrected" "/Specimens.cfm?action=fixedSearch&amp;execute=false" "200" "-" "-" "-" ""

echo "== A session sent back is kept"
rm -f "$WORK/returning.txt"
check "returning client: first request starts a session" "/Specimens.cfm" "200" "1" "-" "-" "" -c "$WORK/returning.txt" -b "$WORK/returning.txt"
check "returning client: second request keeps it" "/Specimens.cfm" "200" "0" "-" "-" "" -c "$WORK/returning.txt" -b "$WORK/returning.txt"
# A browser blocking cookies can carry the session in the url, as ColdFusion's own links with addtoken
# do.  Such a request may show MCZbase's error page; this checks only that the session is kept.
check "url token client: first request starts a session" "/Specimens.cfm" "200" "1" "-" "-" ""
TOKEN_CFID="$CFID_VALUE"
TOKEN_QUERY="CFID=$(urlEncode "$CFID_VALUE")&CFTOKEN=$(urlEncode "$CFTOKEN_VALUE")"
# checkUrlTokenKept fails if the url token request was given a different session.
# @param $1 description.
checkUrlTokenKept() {
	check "$1" "/Specimens.cfm?$TOKEN_QUERY" "200" "-" "-" "-" "allowerror"
	if [ "$CFIDS" != "0" ] && [ "$CFID_VALUE" != "$TOKEN_CFID" ]; then
		fail "$1: given a new session"
	fi
}
checkUrlTokenKept "url token client: second request keeps it"
check "made up session cookie starts a new session" "/Specimens.cfm" "200" "1" "-" "-" "" -b "CFID=1;CFTOKEN=00000000-0000-0000-0000000000000000"

# requireFooter fails the previous check's response if it lacks the page footer, as when a page stops early.
# @param $1 description.
requireFooter() {
	# shared/_footer.cfm has a footer element, includes/_footer.cfm (used by onError) footerContentBox
	if ! grep -Eq '<footer|id="footerContentBox"' "$WORK/body"; then
		fail "$1: page has no footer"
	fi
}

echo "== Refused requests: header, Access denied and footer, 403, one session"
check "anonymous /Admin/ page" "/Admin/AdminPanel.cfm" "403" "1" "-" "Access denied" "allowerror"
requireFooter "anonymous /Admin/ page"
check "anonymous /tools/ page" "/tools/access_report.cfm" "403" "1" "-" "Access denied" "allowerror"
requireFooter "anonymous /tools/ page"
check "/CustomTags/" "/CustomTags/rolecheck.cfm" "403" "1" "-" "Access denied" "allowerror"
requireFooter "/CustomTags/"
check "/log/" "/log/index.cfm" "403" "1" "-" "Access denied" "allowerror"
requireFooter "/log/"
# Folders Application.cfc refuses to a visitor before the page runs, so no parameters are needed.
for page in /Bulkloader/BulkloaderCheck.cfm /Bulkloader/index.cfm /Reports/LoanInstructions.cfm \
		/Admin/ActivityLog.cfm /tools/BulkPartSample.cfm /tools/DataLoanBulkload.cfm; do
	check "anonymous $page" "$page" "403" "1" "-" "Access denied" "allowerror"
	requireFooter "anonymous $page"
done
for page in AddrPick condition DeleteEncumbrance findAccn findAgent findAgentName findBorrow \
		findCatalogedItem findCollEvent findDeaccession findDOI findHigherGeog findLoan findMedia \
		findNamedGroup findPart_Attribute findPart findPermit findPublication getAgentName getAttributeValues \
		getPart_Attribute index KewAbbrPick LocalityPick preserve TaxaPick; do
	check "anonymous /picks/$page.cfm" "/picks/$page.cfm" "403" "1" "-" "Access denied" "allowerror"
	requireFooter "anonymous /picks/$page.cfm"
done
# Upload pages removed from MCZbase; a server still holding a copy would answer 200 or 500
for page in /tools/uploadMedia.cfm /info/upMedia.cfm /info/upMediaPreview.cfm; do
	check "removed $page" "$page" "403|404" "-" "-" "-" "allowerror"
done
# Elsewhere the header's role check refuses them, ending the page after its message, so without a footer.
for page in /DataEntry.cfm /media.cfm /info/queryStats.cfm /info/recentgeorefs.cfm /loanByBarcode.cfm \
		/containers/browseContainers.cfm /Citation.cfm /reporting/Reports.cfm /Transactions.cfm /TAG.cfm; do
	check "anonymous $page" "$page" "403" "1" "-" "not authorized" "allowerror"
done
# loaded inside Data Entry without a header, so it refuses with a redirect
check "anonymous /form/customizeDataEntry.cfm" "/form/customizeDataEntry.cfm" "302" "1" "/errors/forbidden\\.cfm" "-" ""

echo "== Pages a visitor may open: footer, current libraries, and the files they load"
# checkAssets fails the previous check's response if a script or stylesheet it loads from this site, or
# a file a stylesheet refers to, doesn't load.  Each file is requested once per run.
# @param $1 description.
declare -A ASSET_STATUS
checkAssets() {
	local asset missing=""
	for asset in $(grep -oE "(src|href)=[\"']/[^\"'?#]*\.(js|css)" "$WORK/body" | sed -E "s/^(src|href)=[\"']//" | sort -u); do
		if [ -z "${ASSET_STATUS[$asset]}" ]; then
			ASSET_STATUS[$asset]=$(curl -s "${CURL_OPTIONS[@]}" --max-time 60 -o /dev/null -w '%{http_code}' "$HOST$asset")
		fi
		if [ "${ASSET_STATUS[$asset]}" != "200" ]; then
			missing+=" $asset (${ASSET_STATUS[$asset]})"
		fi
		# a stylesheet's own url() references, such as theme images, without those in comments
		if [[ "$asset" == *.css && -z "${ASSET_STATUS[$asset|urls]}" ]]; then
			ASSET_STATUS[$asset|urls]=checked
			local cssDir="${asset%/*}" ref resolved
			for ref in $(curl -s "${CURL_OPTIONS[@]}" --max-time 60 "$HOST$asset" | perl -0pe 's#/\*.*?\*/##gs' \
					| grep -oE "url\(['\"]?[^)'\"]+" | sed -E "s/^url\(['\"]?//" | grep -vE "^(data:|https?:|//|#)" \
					| sed -E 's/[?#].*$//' | sort -u); do
				if [[ "$ref" == /* ]]; then resolved="$ref"; else resolved="$cssDir/$ref"; fi
				resolved=$(echo "$resolved" | sed -E ':a; s#/[^/]+/\.\./#/#; ta; s#/\./#/#g')
				if [ -z "${ASSET_STATUS[$resolved]}" ]; then
					ASSET_STATUS[$resolved]=$(curl -s "${CURL_OPTIONS[@]}" --max-time 60 -o /dev/null -w '%{http_code}' "$HOST$resolved")
				fi
				if [ "${ASSET_STATUS[$resolved]}" != "200" ]; then
					missing+=" $resolved from $asset (${ASSET_STATUS[$resolved]})"
				fi
			done
		fi
	done
	if [ -n "$missing" ]; then
		fail "$1: doesn't load$missing"
	fi
}
# requireAbsent fails the previous check's response if its body matches.
# @param $1 description.
# @param $2 regular expression.
requireAbsent() {
	if grep -Eq "$2" "$WORK/body"; then
		fail "$1: body matches /$2/"
	fi
}
# requireLibraries fails the previous check's response unless it loads the expected jQuery and jQuery UI,
# and Bootstrap too with "bootstrap", or if it still loads a library no page should.
# @param $1 description.
# @param $2 "bootstrap" for a page on the redesign header.
requireLibraries() {
	local library
	for library in "$JQUERY_FILE" "$JQUERY_UI_DIR" $([ "$2" = "bootstrap" ] && echo "$BOOTSTRAP_DIR"); do
		if ! grep -qF "$library" "$WORK/body"; then
			fail "$1: doesn't load $library"
		fi
	done
	requireAbsent "$1" "$OLD_LIBRARIES"
}
# checkVisitorPage checks a page a visitor may open: one session, a footer, the expected libraries, and
# the files it loads.
# @param $1 path.
# @param $2 "bootstrap" for a page on the redesign header.
checkVisitorPage() {
	check "visitor $1" "$1" "200" "1" "-" "-" ""
	requireFooter "visitor $1"
	requireLibraries "visitor $1" "$2"
	checkAssets "visitor $1"
}
for page in /SpecimenSearch.cfm /MediaSearch.cfm /document.cfm /showLocality.cfm /contact.cfm; do
	checkVisitorPage "$page"
done
for page in /Specimens.cfm /Taxa.cfm /Agents.cfm /Publications.cfm /Projects.cfm /media/findMedia.cfm \
		/specimens/PrimaryTypes.cfm /specimens/browseSpecimens.cfm /specimens/viewSpecimenSearchMetadata.cfm \
		/info/HowToCite.cfm; do
	checkVisitorPage "$page" bootstrap
done
check "visitor /SpecimenResults.cfm without criteria" "/SpecimenResults.cfm" "200" "1" "-" "You must enter some search criteria" ""
requireLibraries "visitor /SpecimenResults.cfm without criteria"
checkAssets "visitor /SpecimenResults.cfm without criteria"
# help.cfm is shown in a popup, with the pick header and no footer
check "visitor /info/help.cfm" "/info/help.cfm?content=accn_number&showAsHtml=" "200" "1" "-" "Accession number" ""
requireLibraries "visitor /info/help.cfm"
checkAssets "visitor /info/help.cfm"
fetch "$HOST/SpecimenSearch.cfm"
for i in 1 2 3; do
	if ! grep -q "name=\"attribute_type_$i\"" "$WORK/body"; then
		fail "Specimen Search attribute row $i is missing"
	fi
done

echo "== Legacy Specimen Search type-aheads and results"
# a line per suggestion
check "type-ahead Class" "/ajax/phylclass.cfm?q=Mam" "200" "1" "-" "^Mammalia" ""
check "type-ahead Part Name" "/ajax/part_name.cfm?q=sk" "200" "1" "-" "^skin" ""
check "type-ahead Project Name" "/ajax/project.cfm?q=a" "200" "1" "-" "[A-Za-z]" ""
check "type-ahead Geology Attribute Value" "/ajax/tData.cfm?action=suggestGeologyAttVal&q=a" "200" "1" "-" "[A-Za-z]" ""
check "attribute Pick list" "/info/attributeHelpPick.cfm?attNum=1&attribute=sex" "200" "1" "-" "-" ""
checkAssets "attribute Pick list"

# An attribute search, then what its results page offers, in the one session the results table belongs to.
rm -f "$WORK/visitor.txt"
VISITOR=(-c "$WORK/visitor.txt" -b "$WORK/visitor.txt")
ATTRIBUTE_SEARCH="cat_num=1-100&attribute_type_1=sex&attribute_value_1=male"
check "attribute search results" "/SpecimenResults.cfm?$ATTRIBUTE_SEARCH" "200" "1" "-" "var lla='[0-9]" "" "${VISITOR[@]}"
requireFooter "attribute search results"
RESULTS_TABLE=$(grep -oE "tableName=SpecSrch[A-Za-z0-9_]+" "$WORK/body" | head -1)
HTML_VERSION=$(grep -oE "SpecimenResultsHTML\.cfm\?[^\"']*" "$WORK/body" | head -1 | sed 's/&amp;/\&/g; s/&#x3d;/=/g')
MAP_LINK=$(grep -oE "/bnhmMaps/bnhmMapData\.cfm\?[^\"']*" "$WORK/body" | head -1 | sed 's/&amp;/\&/g; s/&#x3d;/=/g')
check "results grid data" "/component/functions.cfc?method=getSpecResultsData&startrow=1&numrecs=20&orderBy=cat_num%20ASC&returnformat=json&queryformat=column" "200" "0" "-" "COLLECTION_OBJECT_ID" "" "${VISITOR[@]}"
check "results preferences" "/info/SpecimenResultsPrefs.cfm" "200" "0" "-" "-" "" "${VISITOR[@]}"
if [ -n "$RESULTS_TABLE" ]; then
	check "results Download" "/SpecimenResultsDownload.cfm?$RESULTS_TABLE" "200" "0" "-" "-" "" "${VISITOR[@]}"
	requireFooter "results Download"
else
	fail "attribute search results have no Download link"
fi
if [ -n "$MAP_LINK" ]; then
	check "results map" "$MAP_LINK" "200" "0" "-" "-" "" "${VISITOR[@]}"
else
	fail "attribute search results have no map link"
fi
if [ -n "$HTML_VERSION" ]; then
	check "results HTML version" "/$HTML_VERSION" "200" "0" "-" "records that matched" "" "${VISITOR[@]}"
	requireFooter "results HTML version"
	checkAssets "results HTML version"
else
	fail "attribute search results have no HTML version link"
fi
check "results Summary" "/SpecimenResultsSummary.cfm?$ATTRIBUTE_SEARCH&groupBy=phylclass" "200" "0" "-" "-" "" "${VISITOR[@]}"
requireFooter "results Summary"
check "results Graph" "/SpecimenGraph.cfm?$ATTRIBUTE_SEARCH" "200" "0" "-" "-" "" "${VISITOR[@]}"
requireFooter "results Graph"

echo "== Project search: Projects.cfm and its backing methods"
PROJECT_SEARCH="/projects/component/search.cfc?method=search"
# checkProjectSearch checks a call to the project search method: JSON with a row count, one session.
# @param $1 description.
# @param $2 query string to add to the call.
checkProjectSearch() {
	check "project search $1" "$PROJECT_SEARCH&$2" "200" "1" "-" "\"last_row\" *: *[0-9]+" ""
}
checkProjectSearch "by name, one page" "p_title=a&page=1&size=5"
if [ "$STATUS" = "200" ]; then
	PAGE_ROWS=$(grep -o '"project_id"' "$WORK/body" | wc -l)
	PAGE_TOTAL=$(jsonField last_row "$WORK/body")
	if [ "$PAGE_ROWS" -gt 5 ]; then
		fail "project search page of size 5 returned $PAGE_ROWS rows"
	fi
	if [ "${PAGE_TOTAL:-0}" -gt 0 ] && [ "$PAGE_ROWS" -eq 0 ]; then
		fail "project search found $PAGE_TOTAL projects but returned none"
	fi
fi
# Tabulator sends size=true for its All choice
checkProjectSearch "page size All" "p_title=a&size=true"
if [ "$STATUS" = "200" ]; then
	ALL_ROWS=$(grep -o '"project_id"' "$WORK/body" | wc -l)
	ALL_TOTAL=$(jsonField last_row "$WORK/body")
	ALL_PAGES=$(jsonField last_page "$WORK/body")
	if [ "$ALL_PAGES" != "1" ] || [ "$ALL_ROWS" != "${ALL_TOTAL:-0}" ]; then
		fail "project search page size All: $ALL_ROWS rows of $ALL_TOTAL on $ALL_PAGES pages, expected all on one"
	fi
fi
# the results grid's column header filters
for filter in filter_project_name=a filter_participants=a filter_sponsors=a filter_start_date=19 filter_end_date=20; do
	checkProjectSearch "header filter ${filter%%=*}" "$filter"
done
for years in start_year=2010 end_year=2015 end_year=NULL end_year=NOT%20NULL year=2010; do
	checkProjectSearch "${years%%=*} ${years#*=}" "$years"
done
# year, retired from the form but still in old links, includes projects with no end date: still running
checkProjectSearch "ongoing projects" "end_year=NULL"
ONGOING=$(jsonField last_row "$WORK/body")
THIS_YEAR=$(date +%Y)
checkProjectSearch "ongoing projects active this year" "end_year=NULL&year=$THIS_YEAR"
if [ "${ONGOING:-0}" -gt 0 ] && [ "$(jsonField last_row "$WORK/body")" = "0" ]; then
	fail "project search year=$THIS_YEAR leaves out the $ONGOING projects with no end date"
fi
# values the form wouldn't send are ignored rather than failing
for value in start_year=abc end_year=abc year=abc sort_field=bogus sort_dir=sideways page=-3 size=0; do
	checkProjectSearch "ignores $value" "$value"
done
check "project picklist" "/projects/component/search.cfc?method=getProjectAutocompleteMeta&term=a" "200" "1" "-" "\"meta\"" ""
# dates are shown as yyyy-mm-dd, without an Oracle DATE's time
requireAbsent "project picklist" "00:00:00"
checkVisitorPage "/Projects.cfm?execute=true&p_title=a" bootstrap
if ! grep -q "/shared/js/tabulator-common\\.js" "$WORK/body"; then
	fail "visitor /Projects.cfm?execute=true&p_title=a: doesn't load tabulator-common.js"
fi
# loaded only when a grid is exported to Excel, so checkAssets doesn't see it
check "Projects Excel export library" "/lib/ExcelJS/exceljs_ver4.4.0/exceljs.min.js" "200" "0" "-" "-" ""
# the header loads tabulator-common.js only on pages with a Tabulator grid
fetch "$HOST/Taxa.cfm"
if grep -q "tabulator-common\\.js" "$WORK/body"; then
	fail "/Taxa.cfm loads tabulator-common.js but has no Tabulator grid"
fi
# agent ids from the url are written into the agent pickers' script encoded
check "Projects.cfm agent ids in script are encoded" "/Projects.cfm?participant_agent_id=%22%29%3B%2F%2F&sponsor_agent_id=%22%29%3B%2F%2F&transaction_agent_id=%22%29%3B%2F%2F" "200" "1" "-" "-" ""
requireAbsent "Projects.cfm agent ids in script are encoded" '_agent_view", ""\);//"'

echo "== Routes through guid/handler.cfm and errors/missing.cfm"
if [ -n "$CATNUM" ]; then
	GUID="MCZ:Mamm:$CATNUM"
	check "/guid/ specimen page" "/guid/$GUID" "200" "1" "-" "$GUID" ""
	check "/guid/ json" "/guid/$GUID/json" "200" "1" "-" "-" ""
	if [[ "$STATUS" = "200" && "$CONTENT_TYPE" != *json* ]]; then
		fail "/guid/ json content type is [$CONTENT_TYPE]"
	fi
	check "/guid/ turtle" "/guid/$GUID/turtle" "200" "1" "-" "-" ""
	check "/specimen/ old API redirects to /guid/" "/specimen/MCZ/Mamm/$CATNUM" "301" "-" "/guid/$GUID\$" "-" ""
else
	skip "/guid/ specimen page, json, turtle, /specimen/" CATNUM
fi
check "/guid/ for a record that doesn't exist" "/guid/MCZ:Mamm:99999999999" "404" "1" "-" "-" "allowerror"
requireFooter "/guid/ for a record that doesn't exist"
if [ -n "$HIDDEN_GUID" ]; then
	# described without the guid, which names a record that isn't public
	check "/guid/ for a record hidden from the user" "/guid/$(urlEncode "$HIDDEN_GUID")" "404" "1" "-" "-" "allowerror"
	requireFooter "/guid/ for a record hidden from the user"
else
	skip "/guid/ for a record hidden from the user" HIDDEN_GUID
fi
if [ -n "$COLL_OBJECT_ID" ]; then
	check "specimens/Specimen.cfm?collection_object_id= redirects to /guid/" "/specimens/Specimen.cfm?collection_object_id=$COLL_OBJECT_ID" "301" "1" "/guid/" "-" ""
	check "summary header AJAX call" "/specimens/component/public.cfc?method=getSummaryHeaderHTML&collection_object_id=$COLL_OBJECT_ID" "200" "1" "-" "-" ""
else
	skip "specimens/Specimen.cfm?collection_object_id=, summary header AJAX call" COLL_OBJECT_ID
fi
if [ -n "$TAXON_NAME" ]; then
	check "/name/ taxon page" "/name/$(urlEncode "$TAXON_NAME")" "200" "1" "-" "-" ""
else
	skip "/name/ taxon page" TAXON_NAME
fi
if [ -n "$MEDIA_ID" ]; then
	check "/media/{id} media page" "/media/$MEDIA_ID" "200" "1" "-" "-" ""
else
	skip "/media/{id}" MEDIA_ID
fi
if [ -n "$PUBLICATION_ID" ]; then
	check "/publication/{id}" "/publication/$PUBLICATION_ID" "200" "1" "-" "-" ""
else
	skip "/publication/{id}" PUBLICATION_ID
fi
if [ -n "$PROJECT_NAME" ]; then
	check "/project/{name}" "/project/$(urlEncode "${PROJECT_NAME// /-}")" "200" "1" "-" "-" ""
else
	skip "/project/{name}" PROJECT_NAME
fi
if [ -n "$NAMED_GROUP" ]; then
	check "/namedGroup/{name}" "/namedGroup/$(urlEncode "$NAMED_GROUP")" "200" "1" "-" "-" ""
else
	skip "/namedGroup/{name}" NAMED_GROUP
fi
if [ -n "$UUID" ]; then
	check "/uuid/{uuid}" "/uuid/$(urlEncode "$UUID")" "200|301" "1" ".*" "-" ""
else
	skip "/uuid/{uuid}" UUID
fi
check "/uuid/ that doesn't exist" "/uuid/00000000-0000-0000-0000-000000000000" "404" "1" "-" "-" "allowerror"
if [ -n "$SAVED_SEARCH" ]; then
	check "/saved/{name}" "/saved/$(urlEncode "$SAVED_SEARCH")" "200" "1" "-" "-" ""
else
	skip "/saved/{name}" SAVED_SEARCH
fi
check "/saved/ that doesn't exist" "/saved/noSuchSavedSearch" "404" "1" "-" "-" "allowerror"
if [ -n "$DOCUMENT" ]; then
	check "/document/{title}" "/document/$DOCUMENT" "200" "1" "-" "-" ""
else
	skip "/document/{title}" DOCUMENT
fi
check "/api" "/api" "200" "1" "-" "-" ""
check "a page without .cfm answers 404" "/Specimens?action=fixedSearch" "404" "1" "-" "-" "allowerror"
requireFooter "a page without .cfm answers 404"
check "page that doesn't exist" "/no/such/page" "404" "1" "-" "-" "allowerror"
requireFooter "page that doesn't exist"
if [[ "$HOST" == https://* ]]; then
	check "http redirects to https" "http://${HOST#https://}/Specimens.cfm" "301|302" "0" "^https://" "-" ""
fi

if [ "$APACHE" = "1" ]; then
	echo "== Old page redirects made by production's Apache rewrite rules: no ColdFusion, no session"
	check "bare SpecimenDetail.cfm is gone" "/SpecimenDetail.cfm" "410" "0" "-" "-" ""
	if [ -n "$CATNUM" ]; then
		check "SpecimenDetail.cfm?guid= redirects to /guid/" "/SpecimenDetail.cfm?guid=MCZ:Mamm:$CATNUM" "301" "0" "/guid/MCZ:Mamm:$CATNUM\$" "-" ""
	else
		skip "SpecimenDetail.cfm?guid=" CATNUM
	fi
	if [ -n "$COLL_OBJECT_ID" ]; then
		check "SpecimenDetail.cfm?collection_object_id= redirects" "/SpecimenDetail.cfm?collection_object_id=$COLL_OBJECT_ID" "301" "0" "/specimens/Specimen.cfm\\?collection_object_id=$COLL_OBJECT_ID\$" "-" ""
		check "SpecimenDetails.cfm?collection_object_id= redirects" "/SpecimenDetails.cfm?collection_object_id=$COLL_OBJECT_ID" "301" "0" "/specimens/Specimen.cfm\\?collection_object_id=$COLL_OBJECT_ID\$" "-" ""
	else
		skip "SpecimenDetail(s).cfm?collection_object_id=" COLL_OBJECT_ID
	fi
	if [ -n "$TAXON_NAME_ID" ]; then
		check "TaxonomyDetails.cfm redirects" "/TaxonomyDetails.cfm?taxon_name_id=$TAXON_NAME_ID" "301" "0" "/taxonomy/showTaxonomy.cfm\\?taxon_name_id=$TAXON_NAME_ID\$" "-" ""
	else
		skip "TaxonomyDetails.cfm" TAXON_NAME_ID
	fi
	if [ -n "$MEDIA_ID" ]; then
		check "MediaSet.cfm redirects" "/MediaSet.cfm?media_id=$MEDIA_ID" "301" "0" "/media/RelatedMedia.cfm\\?media_id=$MEDIA_ID\$" "-" ""
	else
		skip "MediaSet.cfm" MEDIA_ID
	fi
	if [ -n "$PUBLICATION_ID" ]; then
		check "SpecimenUsage.cfm redirects" "/SpecimenUsage.cfm?publication_id=$PUBLICATION_ID" "301" "0" "/publications/showPublication.cfm\\?publication_id=$PUBLICATION_ID\$" "-" ""
	else
		skip "SpecimenUsage.cfm" PUBLICATION_ID
	fi
fi

if [ "$BROWSER" = "1" ]; then
	echo "== Pages in headless Chromium: no script errors, console errors, security errors or failed requests"
	CHROME=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
	if [ -z "$CHROME" ] || ! command -v node > /dev/null; then
		skip "browser checks" "PATH (needs chromium and node)"
	else
		# browserCheck.js opens each url in a new tab, waits for the load event and then a few seconds
		# for AJAX, and prints PASS or FAIL with what went wrong.  CDP over --remote-debugging-pipe:
		# messages are JSON, each ending with a NUL, on file descriptors 3 (to Chromium) and 4 (from it).
		cat > "$WORK/browserCheck.js" <<'NODE'
const { spawn } = require("child_process");
const fs = require("fs");
const [, , chrome, profile, settleMs, insecure, userAgentTag, axeFile, ...urls] = process.argv;
const axeSource = axeFile ? fs.readFileSync(axeFile, "utf8") : "";
// the developer guide's rules that axe-core doesn't check, run in the page; returns a list of issues
const guideRules = `(() => {
	const issues = [];
	const mains = document.querySelectorAll("main");
	if (mains.length !== 1) { issues.push("guide-main: " + mains.length + " main elements, expected one"); }
	if (!document.querySelector("main#content")) { issues.push("guide-main: no main with id content (the skip link's target)"); }
	document.querySelectorAll("main[role=main]").forEach(() => issues.push("guide-main: main has role=main"));
	const regions = document.querySelectorAll("section[role=region]").length;
	if (regions) { issues.push("guide-section: " + regions + " section elements with role=region"); }
	const visible = (e) => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
	const headings = [...document.querySelectorAll("h1,h2,h3,h4,h5,h6,[role=heading]")].filter(visible).map((h) => ({
		level: Number(h.getAttribute("aria-level") || (h.tagName.match(/^H([1-6])$/) || [0, 2])[1]), text: h.textContent.trim().slice(0, 40) }));
	if (headings.length && headings[0].level !== 1) { issues.push("guide-headings: first heading is h" + headings[0].level + " (" + headings[0].text + ")"); }
	for (let i = 1; i < headings.length; i++) {
		if (headings[i].level > headings[i - 1].level + 1) {
			issues.push("guide-headings: h" + headings[i - 1].level + " then h" + headings[i].level + " (" + headings[i].text + ")");
		}
	}
	document.querySelectorAll("input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=reset]):not([type=image]),select,textarea").forEach((field) => {
		const mechanisms = [];
		if ((field.id && document.querySelector("label[for='" + CSS.escape(field.id) + "']")) || field.closest("label")) { mechanisms.push("label"); }
		if (field.hasAttribute("aria-labelledby")) { mechanisms.push("aria-labelledby"); }
		if (field.hasAttribute("aria-label")) { mechanisms.push("aria-label"); }
		if (field.hasAttribute("title")) { mechanisms.push("title"); }
		if (mechanisms.length > 1) { issues.push("guide-name: " + (field.id || field.name || field.tagName.toLowerCase()) + " is named by " + mechanisms.join(", ")); }
	});
	return issues;
})()`;
const axeRun = `axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] },
	resultTypes: ["violations"] }).then((result) => result.violations.map((v) => v.impact + " " + v.id + " (" + v.nodes.length +
	"): " + v.help + " [" + v.nodes.slice(0, 2).map((n) => n.target.join(" ")).join("; ") + "]"))`;
const cookie = process.env.MCZ_COOKIE || "";
const args = ["--headless=new", "--disable-gpu", "--remote-debugging-pipe", "--no-first-run",
	"--user-data-dir=" + profile, "about:blank"];
if (insecure === "1") { args.unshift("--ignore-certificate-errors"); }
// the browser doesn't need the session cookie in its environment
const env = { ...process.env };
delete env.MCZ_COOKIE;
const browser = spawn(chrome, args, { env, stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
const toBrowser = browser.stdio[3], fromBrowser = browser.stdio[4];
let buffer = "", nextId = 0;
const pending = new Map(), listeners = new Set();
fromBrowser.on("data", (data) => {
	buffer += data.toString();
	let end;
	while ((end = buffer.indexOf("\0")) >= 0) {
		const message = JSON.parse(buffer.slice(0, end));
		buffer = buffer.slice(end + 1);
		if (message.id && pending.has(message.id)) {
			const { resolve, reject } = pending.get(message.id);
			pending.delete(message.id);
			if (message.error) { reject(new Error(message.error.message)); } else { resolve(message.result); }
		} else {
			listeners.forEach((listener) => listener(message));
		}
	}
});
function send(method, params = {}, sessionId) {
	return new Promise((resolve, reject) => {
		const message = { id: ++nextId, method, params };
		if (sessionId) { message.sessionId = sessionId; }
		pending.set(message.id, { resolve, reject });
		toBrowser.write(JSON.stringify(message) + "\0");
	});
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
(async () => {
	const { userAgent } = await send("Browser.getVersion");
	for (const listed of urls) {
		// an a11y: prefix marks a page for the accessibility checks
		const checkAccessibility = listed.startsWith("a11y:");
		const url = checkAccessibility ? listed.slice(5) : listed;
		const site = new URL(url).origin;
		const problems = [], requests = {};
		let loaded = false;
		const { targetId } = await send("Target.createTarget", { url: "about:blank" });
		const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
		const listener = (message) => {
			if (message.sessionId !== sessionId) { return; }
			const p = message.params || {};
			switch (message.method) {
				case "Runtime.exceptionThrown": {
					const d = p.exceptionDetails;
					problems.push("uncaught " + ((d.exception && d.exception.description) || d.text).split("\n")[0] + " at " + (d.url || url) + ":" + (d.lineNumber + 1));
					break;
				}
				case "Runtime.consoleAPICalled":
					if (p.type === "error" || p.type === "assert") {
						problems.push("console." + p.type + " " + p.args.map((a) => a.value !== undefined ? a.value : a.description).join(" ").slice(0, 200));
					}
					break;
				case "Log.entryAdded":
					// network entries repeat what the Network events report; javascript ones, the exceptions
					if (p.entry.level === "error" && p.entry.source !== "network" && p.entry.source !== "javascript") {
						problems.push(p.entry.source + " " + p.entry.text.slice(0, 200));
					}
					break;
				case "Network.requestWillBeSent":
					requests[p.requestId] = p.request.url;
					break;
				case "Network.responseReceived":
					if (p.response.status >= 400 && p.response.url.startsWith(site)) {
						problems.push("HTTP " + p.response.status + " " + p.response.url);
					}
					break;
				case "Network.loadingFailed":
					if (!p.canceled && (requests[p.requestId] || "").startsWith(site)) {
						problems.push("failed " + p.errorText + " " + requests[p.requestId]);
					}
					break;
				case "Page.loadEventFired":
					loaded = true;
					break;
			}
		};
		listeners.add(listener);
		for (const domain of ["Runtime", "Log", "Network", "Page"]) { await send(domain + ".enable", {}, sessionId); }
		await send("Network.setUserAgentOverride", { userAgent: userAgent + " " + userAgentTag }, sessionId);
		if (cookie) {
			const cookies = cookie.split(";").map((c) => c.trim()).filter((c) => c.includes("="))
				.map((c) => ({ name: c.slice(0, c.indexOf("=")), value: c.slice(c.indexOf("=") + 1), url: site,
					secure: site.startsWith("https:"), httpOnly: true }));
			await send("Network.setCookies", { cookies }, sessionId);
		}
		await send("Page.navigate", { url }, sessionId);
		for (let waited = 0; waited < 60000 && !loaded; waited += 200) { await sleep(200); }
		if (!loaded) { problems.push("no load event in 60 seconds"); }
		await sleep(Number(settleMs));
		listeners.delete(listener);
		const unique = [...new Set(problems)];
		console.log((unique.length ? "FAIL  " : "PASS  ") + url.replace(site, "") + (unique.length ? "\n      " + unique.join("\n      ") : ""));
		if (axeSource && checkAccessibility && loaded) {
			const evaluate = async (expression) => {
				const reply = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
				if (reply.exceptionDetails) { return ["checker: " + reply.exceptionDetails.text]; }
				return reply.result.value || [];
			};
			await send("Runtime.evaluate", { expression: axeSource }, sessionId);
			const issues = [...(await evaluate(axeRun)), ...(await evaluate(guideRules))];
			for (const issue of issues) { console.log("A11Y  " + url.replace(site, "") + "  " + issue); }
		}
		await send("Target.closeTarget", { targetId });
	}
	await send("Browser.close").catch(() => {});
})().catch((error) => { console.log("FAIL  browser checker: " + error.message); }).finally(() => browser.kill());
NODE
		BROWSER_PAGES=(/Specimens.cfm "/Specimens.cfm?action=fixedSearch&execute=true&scientific_name=Canis%20lupus"
			/Taxa.cfm "/Taxa.cfm?execute=true&method=getTaxa&action=search&genus=Canis" /Agents.cfm /Publications.cfm
			/Projects.cfm "/Projects.cfm?execute=true&p_title=a" /media/findMedia.cfm /specimens/browseSpecimens.cfm
			/specimens/PrimaryTypes.cfm
			/specimens/viewSpecimenSearchMetadata.cfm /SpecimenSearch.cfm "/SpecimenResults.cfm?$ATTRIBUTE_SEARCH"
			/MediaSearch.cfm /document.cfm /showLocality.cfm /contact.cfm)
		[ -n "$CATNUM" ] && BROWSER_PAGES+=("/guid/MCZ:Mamm:$CATNUM")
		[ -n "$TAXON_NAME" ] && BROWSER_PAGES+=("/name/$(urlEncode "$TAXON_NAME")")
		[ -n "$MEDIA_ID" ] && BROWSER_PAGES+=("/media/$MEDIA_ID")
		[ -n "$PUBLICATION_ID" ] && BROWSER_PAGES+=("/publication/$PUBLICATION_ID")
		[ -n "$PROJECT_NAME" ] && BROWSER_PAGES+=("/project/$(urlEncode "${PROJECT_NAME// /-}")")
		if [ -n "$MCZ_COOKIE" ]; then
			BROWSER_PAGES+=(/DataEntry.cfm "/media.cfm?action=newMedia" /Transactions.cfm /reporting/Reports.cfm
				/info/queryStats.cfm /info/recentgeorefs.cfm /containers/browseContainers.cfm /Citation.cfm
				/loanByBarcode.cfm /Bulkloader/index.cfm /tools/BulkPartSample.cfm /users/UserProfile.cfm
				/localities/Localities.cfm /localities/CollectingEvents.cfm /publications/Journals.cfm
				/grouping/NamedCollection.cfm /metrics/Dashboard.cfm /media/debugMediaGallery.cfm)
		else
			skip "staff pages in the browser" MCZ_COOKIE
		fi
		AXE_FILE=""
		if [ "$ACCESSIBILITY" = "1" ]; then
			AXE_FILE="$(dirname "$0")/vendor/axe-core-4.13.0/axe.min.js"
			if ! echo "c24f097bd2f451d4f933e8bc7d8d539f8672a2ebcb5cc9f9f3eec8ca9470a0c1  $AXE_FILE" | sha256sum -c --status 2>/dev/null; then
				echo "$AXE_FILE is missing or doesn't match its recorded hash; not running it" >&2
				exit 255
			fi
		fi
		# A proof of concept on redesigned public pages, Projects.cfm being the first on Tabulator.
		# Projects.cfm with results, so the grid is checked as well as the search form
		ACCESSIBILITY_PAGES=(/Specimens.cfm /Taxa.cfm /Projects.cfm "/Projects.cfm?execute=true&p_title=a" /media/findMedia.cfm)
		[ -n "$CATNUM" ] && ACCESSIBILITY_PAGES+=("/guid/MCZ:Mamm:$CATNUM")
		[ -n "$TAXON_NAME" ] && ACCESSIBILITY_PAGES+=("/name/$(urlEncode "$TAXON_NAME")")
		BROWSER_URLS=()
		for page in "${BROWSER_PAGES[@]}"; do
			if [ "$ACCESSIBILITY" = "1" ] && [[ " ${ACCESSIBILITY_PAGES[*]} " == *" $page "* ]]; then
				BROWSER_URLS+=("a11y:$HOST$page")
			else
				BROWSER_URLS+=("$HOST$page")
			fi
		done
		node "$WORK/browserCheck.js" "$CHROME" "$WORK/chrome-profile" 4000 "$INSECURE" "$USER_AGENT" "$AXE_FILE" "${BROWSER_URLS[@]}" > "$WORK/browser.txt" 2>&1
		grep -v "^A11Y  " "$WORK/browser.txt"
		if [ "$ACCESSIBILITY" = "1" ]; then
			echo "== Accessibility of ${#ACCESSIBILITY_PAGES[@]} redesigned pages: axe-core $(grep -o 'axe v[0-9.]*' "$AXE_FILE" | head -1 | cut -c6-) (WCAG 2.1 A and AA) and the developer guide's rules"
			grep "^A11Y  " "$WORK/browser.txt"
			echo "== Accessibility issues by rule: pages, rule"
			# the rule is the word after the impact for axe-core, or the guide- name
			grep "^A11Y  " "$WORK/browser.txt" | awk '{ page = $2; rule = ($3 ~ /^guide-/) ? $3 : $4; sub(/:$/, "", rule);
				if (!seen[page "|" rule]++) { count[rule]++ } } END { for (r in count) printf "%6d  %s\n", count[r], r }' | sort -rn
			A11Y_ISSUES=$(grep -c "^A11Y  " "$WORK/browser.txt")
		fi
		PASSED=$((PASSED + $(grep -c "^PASS  " "$WORK/browser.txt")))
		FAILED=$((FAILED + $(grep -c "^FAIL  " "$WORK/browser.txt")))
	fi
fi

if [ "$SLOW" = "1" ]; then
	echo "== Slow: an unused session ends after 5 minutes, a returning one is kept (waiting 7 minutes)"
	rm -f "$WORK/once.txt"
	check "unused client: first request starts a session" "/Specimens.cfm" "200" "1" "-" "-" "" -c "$WORK/once.txt" -b "$WORK/once.txt"
	sleep 420
	check "unused client: after 7 minutes its session has ended" "/Specimens.cfm" "200" "1" "-" "-" "" -c "$WORK/once.txt" -b "$WORK/once.txt"
	check "returning client: after 7 minutes its session is kept" "/Specimens.cfm" "200" "0" "-" "-" "" -c "$WORK/returning.txt" -b "$WORK/returning.txt"
	checkUrlTokenKept "url token client: after 7 minutes its session is kept"
fi

echo "== $PASSED passed, $FAILED failed, $SKIPPED skipped${A11Y_ISSUES:+, $A11Y_ISSUES accessibility issues}"
if [ "$FAILED" -gt 255 ]; then
	exit 255
fi
exit "$FAILED"

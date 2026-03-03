#!/usr/bin/env python3
"""
Post-install patches for instaloader (applied after pip install).

Fixes two issues in the fork's code:
1. from_username() tries TopSearchResults first, which wastes 3 retries on a
   deprecated endpoint.  Reorder to try GraphQL first, TopSearchResults last,
   with try/except so failures fall through.
2. Instagram now returns 401 "Please wait" for rate limiting instead of 429.
   The retry logic only backs off for 429, so 401 rate-limits get hammered
   with instant retries.  Treat 401 "wait" as TooManyRequestsException.
"""

import importlib.util
import sys
from pathlib import Path


def _find_package_dir() -> Path:
    """Return the directory containing the installed instaloader package."""
    spec = importlib.util.find_spec("instaloader")
    if spec is None or spec.submodule_search_locations is None:
        print("ERROR: instaloader package not found", file=sys.stderr)
        sys.exit(1)
    return Path(list(spec.submodule_search_locations)[0])


def _patch_file(path: Path, old: str, new: str, label: str) -> bool:
    """Replace *old* with *new* in *path*.  Returns True if a change was made."""
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"  [skip] {label} (already patched)")
        return False
    if old not in text:
        print(f"  [WARN] {label} - expected code not found, skipping", file=sys.stderr)
        return False
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"  [ok]   {label}")
    return True


def patch_from_username(pkg: Path) -> bool:
    """Reorder from_username: GraphQL first, TopSearchResults fallback."""
    structures = pkg / "structures.py"

    old = """\
        for profile in TopSearchResults(context, username).get_profiles():
            if profile.username.lower() == username.lower():
                profile._obtain_metadata()
                return profile

        variables = {
            "data": {
                "count":12,
                "include_reel_media_seen_timestamp": False,
                "include_relationship_info": True,
                "latest_besties_reel_media": False,
                "latest_reel_media": False
            },
            "username":username
        }

        data = context.doc_id_graphql_query('34579740524958711', variables)
        try:
            user_info = data["data"]["xdt_api__v1__feed__user_timeline_graphql_connection"]["edges"][0]["node"]["user"]
            profile = cls(context, user_info)
            profile._obtain_metadata()
            return profile
        except (KeyError, IndexError):
            pass

        raise ProfileNotExistsException("No profile found, the user may have blocked you (ID: " +
                                        str(username) + ").")\
"""

    new = """\
        # Try GraphQL first (most reliable, avoids deprecated search endpoint)
        try:
            variables = {
                "data": {
                    "count": 12,
                    "include_reel_media_seen_timestamp": False,
                    "include_relationship_info": True,
                    "latest_besties_reel_media": False,
                    "latest_reel_media": False
                },
                "username": username
            }
            data = context.doc_id_graphql_query('34579740524958711', variables)
            user_info = data["data"]["xdt_api__v1__feed__user_timeline_graphql_connection"]["edges"][0]["node"]["user"]
            profile = cls(context, user_info)
            profile._obtain_metadata()
            return profile
        except (ConnectionException, KeyError, IndexError):
            pass

        # Fall back to TopSearchResults (deprecated, may not work without auth)
        try:
            for profile in TopSearchResults(context, username).get_profiles():
                if profile.username.lower() == username.lower():
                    profile._obtain_metadata()
                    return profile
        except (ConnectionException, KeyError):
            pass

        raise ProfileNotExistsException("No profile found, the user may have blocked you (ID: " +
                                        str(username) + ").")\
"""

    return _patch_file(structures, old, new, "from_username: GraphQL-first ordering")


def patch_get_posts_doc_id(pkg: Path) -> bool:
    """Replace revoked doc_id in get_posts() with the new working one (PR #2663).

    Instagram revoked doc_id 7898261790222653 used by Profile.get_posts() when
    logged in.  The new doc_id 34579740524958711 uses the same endpoint and is
    already in use by from_username(), so it is known-good.
    """
    structures = pkg / "structures.py"

    old = '            doc_id="7898261790222653" if logged_in else "7950326061742207",'
    new = '            doc_id="34579740524958711" if logged_in else "7950326061742207",'

    return _patch_file(structures, old, new, "get_posts: replace revoked doc_id (PR #2663)")


def patch_401_rate_limit(pkg: Path) -> bool:
    """Treat 401 'Please wait' responses as TooManyRequestsException."""
    ctx = pkg / "instaloadercontext.py"

    old = """\
            if resp.status_code == 429:
                raise TooManyRequestsException(self._response_error(resp))
            if resp.status_code != 200:\
"""

    new = """\
            if resp.status_code == 429:
                raise TooManyRequestsException(self._response_error(resp))
            if resp.status_code == 401:
                # Instagram uses 401 with "Please wait" for rate limiting
                try:
                    if "wait" in resp.json().get("message", "").lower():
                        raise TooManyRequestsException(self._response_error(resp))
                except (json.decoder.JSONDecodeError, AttributeError):
                    pass
            if resp.status_code != 200:\
"""

    return _patch_file(ctx, old, new, "get_json: 401 rate-limit backoff")


def main():
    print("Patching instaloader...")
    pkg = _find_package_dir()
    p1 = patch_from_username(pkg)
    p2 = patch_get_posts_doc_id(pkg)
    p3 = patch_401_rate_limit(pkg)
    if p1 or p2 or p3:
        print("Done - patches applied.")
    else:
        print("Done - no changes needed.")


if __name__ == "__main__":
    main()

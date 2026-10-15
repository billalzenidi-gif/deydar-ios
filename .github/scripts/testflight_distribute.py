"""Après l'envoi d'un build (workflow TestFlight) : attend qu'Apple l'ait traité, écrit le « À tester »,
l'ajoute au groupe de testeurs demandé et, pour un groupe externe, le soumet à la Beta Review.
Appelle l'API App Store Connect avec la clé des secrets ASC_* (jeton ES256 de 20 min, refait à chaque appel)."""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
APP_ID = os.environ["APP_ID"]
BUILD = os.environ["BUILD"]
VERSION = os.environ["VERSION"]
GROUP = os.environ.get("GROUP", "").strip()
NOTES = os.environ.get("NOTES", "").strip()

_p8 = os.environ["ASC_KEY_P8"]
PRIVATE_KEY = _p8 if "BEGIN PRIVATE KEY" in _p8 else base64.b64decode(_p8).decode()


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        PRIVATE_KEY, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, params=None):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw.decode(errors="replace")}


def errors(res):
    return "; ".join(f"{e.get('title', '')} {e.get('detail', '')}".strip() for e in res.get("errors", [])) or json.dumps(res)[:500]


def fail(msg):
    print(f"::error::{msg}")
    sys.exit(1)


# 1. Attente du traitement par Apple (le build apparaît quelques minutes après l'envoi).
build_id, deadline = None, time.time() + 50 * 60
while time.time() < deadline:
    status, res = call("GET", "/builds", params={
        "filter[app]": APP_ID, "filter[version]": BUILD, "filter[preReleaseVersion.version]": VERSION,
        "fields[builds]": "version,processingState"})
    if status != 200:
        fail(f"Lecture des builds impossible ({status}) : {errors(res)}")
    data = res.get("data") or []
    state = data[0]["attributes"]["processingState"] if data else "pas encore reçu"
    print(f"Build {VERSION} ({BUILD}) : {state}", flush=True)
    if state == "VALID":
        build_id = data[0]["id"]
        break
    if state in ("FAILED", "INVALID"):
        fail(f"Apple a refusé le build au traitement ({state}). Voir l'e-mail d'App Store Connect.")
    time.sleep(30)
if not build_id:
    fail("Toujours pas traité après 50 min : ajoute le build au groupe à la main dans App Store Connect.")

# 2. « À tester » (anglais), visible des testeurs dans TestFlight.
if NOTES:
    status, res = call("GET", f"/builds/{build_id}/betaBuildLocalizations")
    loc = next((l for l in res.get("data", []) if l["attributes"].get("locale") == "en-US"), None)
    if loc:
        status, res = call("PATCH", f"/betaBuildLocalizations/{loc['id']}", {
            "data": {"type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": NOTES}}})
    else:
        status, res = call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": NOTES},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    print("« À tester » enregistré." if status in (200, 201) else f"::warning::« À tester » non enregistré ({status}) : {errors(res)}")

# 3. Groupe de testeurs.
status, res = call("GET", "/betaGroups", params={
    "filter[app]": APP_ID, "fields[betaGroups]": "name,isInternalGroup,publicLink,publicLinkEnabled", "limit": 200})
if status != 200:
    fail(f"Lecture des groupes impossible ({status}) : {errors(res)}")
group = next((g for g in res.get("data", []) if g["attributes"]["name"] == GROUP), None)
if not group:
    fail(f"Groupe « {GROUP} » introuvable. Groupes existants : " + ", ".join(g["attributes"]["name"] for g in res.get("data", [])))
status, res = call("POST", f"/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build_id}]})
if status not in (200, 204):
    fail(f"Ajout au groupe « {GROUP} » impossible ({status}) : {errors(res)}")
print(f"Build ajouté au groupe « {GROUP} ».")

# 4. Beta Review (groupes externes seulement ; les groupes internes reçoivent le build tout de suite).
if group["attributes"].get("isInternalGroup"):
    print("Groupe interne : les testeurs reçoivent le build sans vérification d'Apple.")
else:
    status, res = call("POST", "/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    if status == 201:
        print("Soumis à la Beta Review d'Apple : le lien public le proposera dès l'approbation.")
    else:
        print(f"::warning::Soumission à la Beta Review non faite ({status}) : {errors(res)}")
    link = group["attributes"].get("publicLink")
    if link and group["attributes"].get("publicLinkEnabled"):
        print(f"Lien public : {link}")

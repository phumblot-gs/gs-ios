#!/usr/bin/env python3
"""Patches GSApp/Localizable.xcstrings:

1. Adds entries that exist in the code but not yet in the catalog
   (Xcode only updates the catalog interactively, so background
   builds don't pick up renamed/added literals).
2. Marks now-removed keys as `extractionState: stale` so they
   stop shipping.
3. Adds FR + PL translations for every key that's still missing
   one, sourcing from a hand-curated table.

Idempotent: re-run after every batch of UI string changes.
"""

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
XCSTRINGS = REPO_ROOT / "GSApp" / "Localizable.xcstrings"

# Newly-added or recently-renamed EN-source keys that the Swift
# compiler hasn't auto-extracted yet. Listed here so the catalog
# stays in sync without manual Xcode interaction.
NEW_KEYS: list[str] = [
    "Coming soon",
    "Tech-view captures now live on the reference detail screen (Scanner tab).",
    "Features",
    "Measures",
    "Turn OCR off on devices where Vision is slow or unreliable. Turn Measures off on devices without LiDAR to fall back to plain photo capture under the Measurement filename pattern.",
    "Uploading…",
    "OAuth callback didn't include a session id.",
    "Backend returned %lld. %@",
    "Couldn't reach the mobile backend. Check connectivity.",
    "Sign-in failed: %@",
    "Reference is missing a reference_id.",
]

# Keys that were French-source literals we replaced with English
# equivalents. Marking them stale keeps the catalog tidy.
STALE_KEYS: list[str] = [
    "Fonctionnalités",
    "Envoi…",
    "Désactive l'OCR sur les devices où Vision est lent ou imprécis. Désactive Mesures sur les devices sans LiDAR pour basculer en capture photo simple sous le pattern Measurement.",
    "Bientôt disponible",
    "La prise de vues techniques se fait désormais depuis la fiche d'une référence (onglet Scanner).",
]

# FR translations for every key that still lacks one — covers
# both the freshly-added NEW_KEYS and pre-existing English-source
# strings that hadn't been translated. Idempotent: keys already
# translated keep their value (the script only fills missing).
FR: dict[str, str] = {
    # New keys
    "Coming soon": "Bientôt disponible",
    "Tech-view captures now live on the reference detail screen (Scanner tab).": "La prise de vues techniques se fait désormais depuis la fiche d'une référence (onglet Scanner).",
    "Features": "Fonctionnalités",
    "Measures": "Mesures",
    "Turn OCR off on devices where Vision is slow or unreliable. Turn Measures off on devices without LiDAR to fall back to plain photo capture under the Measurement filename pattern.": "Désactivez l'OCR sur les appareils où Vision est lent ou imprécis. Désactivez Mesures sur les appareils sans LiDAR pour basculer en capture photo simple sous le pattern Measurement.",
    "Uploading…": "Envoi…",
    "OAuth callback didn't include a session id.": "Le retour OAuth n'a pas fourni d'identifiant de session.",
    "Backend returned %lld. %@": "Le backend a répondu %lld. %@",
    "Couldn't reach the mobile backend. Check connectivity.": "Impossible de joindre le backend mobile. Vérifiez la connectivité.",
    "Sign-in failed: %@": "Échec de connexion : %@",
    "Reference is missing a reference_id.": "La référence n'a pas de reference_id.",

    # Format-only / structural — keep as-is
    "—": "—",
    "· %@": "· %@",
    "· %@ points": "· %@ points",
    "· EAN %@": "· EAN %@",
    "#%@": "#%@",
    "#%@ · %@": "#%1$@ · %2$@",
    "%@": "%@",
    "%@ measurements": "%@ mesures",
    "%@ mm": "%@ mm",
    "%@ point(s)": "%@ point(s)",
    "%@ view(s) expected": "%@ vue(s) attendue(s)",
    "%@%%": "%@ %%",
    "%@×": "%@×",
    "Added · %@": "Ajouté · %@",

    # Settings / picker labels
    "Always Presentation": "Toujours Présentation",
    "Remember last": "Mémoriser le dernier",
    "Filename patterns": "Nommage des fichiers",
    "Focal length (35mm equivalent)": "Focale (équivalent 35 mm)",
    "Default status applied to newly-registered stock items. Refresh pulls fresh zones, categories, and batch types from Grand Shooting.": "Statut appliqué par défaut aux nouveaux articles. Actualiser récupère les zones, catégories et types de lots depuis Grand Shooting.",
    "Only enabled statuses appear in the change-status picker. The default-on-register status is always enabled.": "Seuls les statuts activés apparaissent dans le sélecteur. Le statut par défaut à l'enregistrement reste toujours activé.",
    "Optional. Links this category to a Grand Shooting catalog category so the app can cross-check the link at startup.": "Optionnel. Permet de relier cette catégorie à une catégorie du catalogue Grand Shooting pour vérifier le lien au démarrage.",
    "Optional. Tap the wand to generate a random EAN-13 you can print and stick on the box.": "Optionnel. Touchez la baguette pour générer un EAN-13 aléatoire à imprimer et coller sur la boîte.",
    "Selects which deployed Lambda backend the app talks to.": "Choisit le backend Lambda déployé que l'application interroge.",
    "Used as a Bearer token when no OAuth session is active. Stored in the Keychain.": "Utilisé comme jeton Bearer en l'absence de session OAuth. Stocké dans le trousseau.",
    "Studio area you are currently working in. Newly-created batches default to this zone.": "Espace studio où vous travaillez actuellement. Les nouveaux lots y sont rattachés par défaut.",
    "Values offered when creating or editing a batch. Seeded from your existing batches; you can remove unwanted entries here.": "Valeurs proposées à la création ou à l'édition d'un lot. Initialisées depuis vos lots existants — supprimez ici celles qui ne servent pas.",
    "Which catalog attribute the scanned value is looked up against. Use `ean` unless your products are barcoded by their `ref` instead.": "Attribut du catalogue interrogé pour chaque scan. Utilisez `ean` sauf si vos produits sont étiquetés par leur `ref`.",
    "Restart the app for a language change to take full effect.": "Redémarrez l'application pour appliquer pleinement le changement de langue.",

    # Misc UI strings
    "%@ already has %@ stock item(s) in this batch.": "%@ possède déjà %@ article(s) dans ce lot.",
    "Available placeholders: `{EAN}` (falls back to `{REF}` when the reference has no EAN), `{REF}` (catalog reference), `{INC}` (1-based capture counter, seeded from today's GS production so a re-capture on a different day starts back at 1). Always end with `.jpg`. Patterns that resolve to the same filename family share the counter — uploads never overwrite each other.": "Champs disponibles : `{EAN}` (retombe sur `{REF}` quand la référence n'a pas d'EAN), `{REF}` (référence catalogue), `{INC}` (compteur de capture commençant à 1, initialisé depuis la production GS du jour pour qu'une nouvelle capture un autre jour reparte de 1). Terminez toujours par `.jpg`. Les patterns produisant la même famille de noms partagent le compteur — aucun upload n'écrase un autre.",
    "Batch info": "Détails du lot",
    "Category #%@": "Catégorie #%@",
    "Choose label": "Choisir une étiquette",
    "Configure a shooting method in Settings → Grand Shooting before capturing tech views.": "Configurez une méthode de prise de vue dans Réglages → Grand Shooting avant de capturer des vues techniques.",
    "Contents": "Contenu",
    "EAN %@": "EAN %@",
    "GS Mobile": "GS Mobile",
    "Match": "Correspondance",
    "Metadata": "Métadonnées",
    "New label": "Nouvelle étiquette",
    "New pictogram label": "Nouveau libellé de pictogramme",
    "nil": "nil",
    "No batch types known yet. They populate from your account's batches on the next refresh.": "Aucun type de lot connu pour l'instant. Ils apparaîtront à la prochaine actualisation depuis vos lots.",
    "No batches yet.": "Aucun lot pour l'instant.",
    "OCR confidence: %@%%": "Confiance OCR : %@ %%",
    "Other…": "Autre…",
    "Point %@ — hold steady, or tap anywhere to lock.": "Point %@ — maintenez l'appareil immobile, ou touchez l'écran pour verrouiller.",
    "Pull to refresh, or tap Retry.": "Tirez pour actualiser, ou touchez Réessayer.",
    "Rank %@": "Position %@",
    "References you scan or open from search will appear here.": "Les références scannées ou ouvertes depuis la recherche apparaîtront ici.",
    "Registering %@…": "Enregistrement de %@…",
    "Registering to %@": "Enregistrement dans %@",
    "Stock items (%@)": "Articles (%@)",
    "Stock items are always linked to a batch. Pick the box, shelf or pallet you're registering into.": "Les articles sont toujours liés à un lot. Choisissez la boîte, l'étagère ou la palette concernée.",
    "Tap + to create your first batch, or scan one to open it.": "Touchez + pour créer votre premier lot, ou scannez-en un pour l'ouvrir.",
    "Tap to categorise": "Touchez pour catégoriser",
    "Tech views": "Vues techniques",
    "Text": "Texte",
    "This batch is empty.": "Ce lot est vide.",
    "Updating…": "Mise à jour…",
    "Uses %@ (%@ mm) × %@.": "Utilise %@ (%@ mm) × %@.",
    "Z": "Z",
}

# PL — same key set as FR.
PL: dict[str, str] = {
    "Coming soon": "Wkrótce dostępne",
    "Tech-view captures now live on the reference detail screen (Scanner tab).": "Ujęcia techniczne wykonuje się teraz z poziomu strony referencji (zakładka Skaner).",
    "Features": "Funkcje",
    "Measures": "Pomiary",
    "Turn OCR off on devices where Vision is slow or unreliable. Turn Measures off on devices without LiDAR to fall back to plain photo capture under the Measurement filename pattern.": "Wyłącz OCR na urządzeniach, gdzie Vision działa wolno lub niepewnie. Wyłącz Pomiary na urządzeniach bez LiDAR, aby przełączyć się na zwykłe zdjęcia pod wzorcem nazewnictwa Measurement.",
    "Uploading…": "Wysyłanie…",
    "OAuth callback didn't include a session id.": "Odpowiedź OAuth nie zawierała identyfikatora sesji.",
    "Backend returned %lld. %@": "Backend zwrócił %lld. %@",
    "Couldn't reach the mobile backend. Check connectivity.": "Nie można połączyć się z mobilnym backendem. Sprawdź połączenie.",
    "Sign-in failed: %@": "Logowanie nie powiodło się: %@",
    "Reference is missing a reference_id.": "Referencja nie ma pola reference_id.",

    "—": "—",
    "· %@": "· %@",
    "· %@ points": "· %@ punktów",
    "· EAN %@": "· EAN %@",
    "#%@": "#%@",
    "#%@ · %@": "#%1$@ · %2$@",
    "%@": "%@",
    "%@ measurements": "%@ pomiarów",
    "%@ mm": "%@ mm",
    "%@ point(s)": "%@ punktów",
    "%@ view(s) expected": "Oczekiwane ujęć: %@",
    "%@%%": "%@ %%",
    "%@×": "%@×",
    "Added · %@": "Dodano · %@",

    "Always Presentation": "Zawsze Prezentacja",
    "Remember last": "Zapamiętaj ostatni",
    "Filename patterns": "Wzorce nazw plików",
    "Focal length (35mm equivalent)": "Ogniskowa (ekwiwalent 35 mm)",
    "Default status applied to newly-registered stock items. Refresh pulls fresh zones, categories, and batch types from Grand Shooting.": "Status nadawany domyślnie nowo rejestrowanym pozycjom. Odświeżanie pobiera strefy, kategorie i typy partii z Grand Shooting.",
    "Only enabled statuses appear in the change-status picker. The default-on-register status is always enabled.": "W selektorze zmiany statusu pojawiają się tylko statusy włączone. Status domyślny przy rejestracji zawsze pozostaje włączony.",
    "Optional. Links this category to a Grand Shooting catalog category so the app can cross-check the link at startup.": "Opcjonalnie. Łączy tę kategorię z kategorią katalogu Grand Shooting, aby aplikacja mogła sprawdzić powiązanie przy starcie.",
    "Optional. Tap the wand to generate a random EAN-13 you can print and stick on the box.": "Opcjonalnie. Dotknij różdżki, aby wygenerować losowy EAN-13 do wydrukowania i naklejenia na pudełko.",
    "Selects which deployed Lambda backend the app talks to.": "Wybiera, z którym wdrożonym backendem Lambda komunikuje się aplikacja.",
    "Used as a Bearer token when no OAuth session is active. Stored in the Keychain.": "Używany jako token Bearer, gdy brak aktywnej sesji OAuth. Przechowywany w Pęku kluczy.",
    "Studio area you are currently working in. Newly-created batches default to this zone.": "Strefa studia, w której obecnie pracujesz. Nowo utworzone partie domyślnie trafiają do tej strefy.",
    "Values offered when creating or editing a batch. Seeded from your existing batches; you can remove unwanted entries here.": "Wartości proponowane przy tworzeniu lub edycji partii. Pochodzą z istniejących partii — możesz tu usunąć niepotrzebne pozycje.",
    "Which catalog attribute the scanned value is looked up against. Use `ean` unless your products are barcoded by their `ref` instead.": "Atrybut katalogu, względem którego zeskanowana wartość jest wyszukiwana. Użyj `ean`, chyba że produkty są oznaczane kodem `ref`.",
    "Restart the app for a language change to take full effect.": "Uruchom aplikację ponownie, aby zmiana języka zadziałała w pełni.",

    "%@ already has %@ stock item(s) in this batch.": "%@ ma już %@ pozycji w tej partii.",
    "Available placeholders: `{EAN}` (falls back to `{REF}` when the reference has no EAN), `{REF}` (catalog reference), `{INC}` (1-based capture counter, seeded from today's GS production so a re-capture on a different day starts back at 1). Always end with `.jpg`. Patterns that resolve to the same filename family share the counter — uploads never overwrite each other.": "Dostępne pola: `{EAN}` (przechodzi na `{REF}`, gdy referencja nie ma EAN), `{REF}` (referencja katalogowa), `{INC}` (licznik ujęć od 1, zaczerpnięty z dzisiejszej produkcji GS, aby ponowne ujęcie w inny dzień rozpoczynało się od 1). Zawsze zakończ `.jpg`. Wzorce dające tę samą rodzinę nazw współdzielą licznik — uploady się nie nadpisują.",
    "Batch info": "Informacje o partii",
    "Category #%@": "Kategoria #%@",
    "Choose label": "Wybierz etykietę",
    "Configure a shooting method in Settings → Grand Shooting before capturing tech views.": "Skonfiguruj metodę zdjęciową w Ustawienia → Grand Shooting przed wykonaniem ujęć technicznych.",
    "Contents": "Zawartość",
    "EAN %@": "EAN %@",
    "GS Mobile": "GS Mobile",
    "Match": "Dopasowanie",
    "Metadata": "Metadane",
    "New label": "Nowa etykieta",
    "New pictogram label": "Nowa etykieta piktogramu",
    "nil": "nil",
    "No batch types known yet. They populate from your account's batches on the next refresh.": "Brak znanych typów partii. Pojawią się po kolejnym odświeżeniu z partii konta.",
    "No batches yet.": "Brak partii.",
    "OCR confidence: %@%%": "Pewność OCR: %@ %%",
    "Other…": "Inne…",
    "Point %@ — hold steady, or tap anywhere to lock.": "Punkt %@ — trzymaj nieruchomo lub dotknij ekranu, aby zablokować.",
    "Pull to refresh, or tap Retry.": "Przeciągnij, aby odświeżyć, lub dotknij Spróbuj ponownie.",
    "Rank %@": "Pozycja %@",
    "References you scan or open from search will appear here.": "Tutaj pojawią się referencje skanowane lub otwierane z wyszukiwarki.",
    "Registering %@…": "Rejestrowanie %@…",
    "Registering to %@": "Rejestrowanie w %@",
    "Stock items (%@)": "Pozycje magazynowe (%@)",
    "Stock items are always linked to a batch. Pick the box, shelf or pallet you're registering into.": "Pozycje magazynowe są zawsze powiązane z partią. Wybierz pudełko, półkę lub paletę, do której rejestrujesz.",
    "Tap + to create your first batch, or scan one to open it.": "Dotknij +, aby utworzyć pierwszą partię, lub zeskanuj jedną, by ją otworzyć.",
    "Tap to categorise": "Dotknij, aby skategoryzować",
    "Tech views": "Ujęcia techniczne",
    "Text": "Tekst",
    "This batch is empty.": "Ta partia jest pusta.",
    "Updating…": "Aktualizowanie…",
    "Uses %@ (%@ mm) × %@.": "Używa %@ (%@ mm) × %@.",
    "Z": "Z",
}


def main() -> None:
    with XCSTRINGS.open() as f:
        catalog = json.load(f)

    strings = catalog.setdefault("strings", {})

    # 1. Insert new EN-source keys (no localizations yet).
    added = 0
    for key in NEW_KEYS:
        if key not in strings:
            strings[key] = {"extractionState": "manual"}
            added += 1

    # 2. Mark renamed keys as stale.
    staled = 0
    for key in STALE_KEYS:
        entry = strings.get(key)
        if entry is None:
            continue
        if entry.get("extractionState") != "stale":
            entry["extractionState"] = "stale"
            staled += 1

    # 3. Fill in FR + PL for every key that's missing one.
    fr_added = 0
    pl_added = 0
    for key, entry in strings.items():
        if entry.get("extractionState") == "stale":
            continue
        locs = entry.setdefault("localizations", {})
        if "fr" not in locs and key in FR:
            locs["fr"] = {"stringUnit": {"state": "translated", "value": FR[key]}}
            fr_added += 1
        if "pl" not in locs and key in PL:
            locs["pl"] = {"stringUnit": {"state": "translated", "value": PL[key]}}
            pl_added += 1

    # Re-key the catalog so new keys land alongside their siblings
    # in alpha order — pure cosmetic but keeps diffs readable.
    catalog["strings"] = {k: strings[k] for k in sorted(strings.keys())}

    with XCSTRINGS.open("w") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"new_keys_added={added} staled={staled} fr_added={fr_added} pl_added={pl_added}")


if __name__ == "__main__":
    main()

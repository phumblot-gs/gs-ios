#!/usr/bin/env python3
"""Adds Polish translations to GSApp/Localizable.xcstrings.

For every key with a `fr` translation, adds a `pl` translation
using a hand-curated FR→PL dictionary (and falls back to the EN
or FR text when the term isn't in the dictionary — typically
brand-specific jargon like "EAN", "stock", "shooting method").

Run from repo root:  bin/add_polish_translations.py
The script is idempotent — re-running it overwrites existing
`pl` entries with fresh translations from the dictionary.
"""

import json
import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
XCSTRINGS = REPO_ROOT / "GSApp" / "Localizable.xcstrings"

# Translation table. Source key is the EN string used as the
# xcstrings key. Value is the Polish translation. Entries with
# format specifiers (%@, %lld) preserve them verbatim.
PL: dict[str, str] = {
    # --- Common UI ---
    "OK": "OK",
    "Cancel": "Anuluj",
    "Done": "Gotowe",
    "Save": "Zapisz",
    "Retake": "Powtórz",
    "Retry": "Spróbuj ponownie",
    "Clear": "Wyczyść",
    "Edit": "Edytuj",
    "Delete": "Usuń",
    "Next": "Dalej",
    "Back": "Wstecz",
    "Continue": "Kontynuuj",
    "Validate": "Zatwierdź",
    "Loading…": "Ładowanie…",
    "Refresh": "Odśwież",
    "Search": "Szukaj",
    "Settings": "Ustawienia",
    "Profile": "Profil",
    "Photo": "Zdjęcie",
    "Scan": "Skanuj",
    "Measures": "Pomiary",
    "History": "Historia",
    "System": "Systemowy",
    "Add": "Dodaj",
    "Sign in": "Zaloguj się",
    "Sign out": "Wyloguj się",

    # --- Tabs / sections ---
    "Scanner": "Skaner",
    "Search references": "Wyszukaj referencje",
    "Take measurements": "Wykonaj pomiary",
    "Retake measurements": "Powtórz pomiary",
    "Capture tech views": "Zrób ujęcia techniczne",
    "Add more tech views": "Dodaj kolejne ujęcia techniczne",
    "Tech views": "Ujęcia techniczne",
    "Metadata": "Metadane",
    "Labels": "Etykiety",
    "Stock items (%lld)": "Pozycje magazynowe (%lld)",
    "Status": "Status",
    "Match": "Dopasowanie",

    # --- Empty states ---
    "No history yet": "Brak historii",
    "References you scan or open from search will appear here.": "Tutaj pojawią się referencje skanowane lub otwierane z wyszukiwarki.",
    "No tech-view pictures yet": "Brak zdjęć ujęć technicznych",
    "No metadata yet": "Brak metadanych",
    "Bientôt disponible": "Wkrótce dostępne",

    # --- Errors / banners ---
    "Couldn't load reference": "Nie można wczytać referencji",
    "Reference not found.": "Nie znaleziono referencji.",
    "Couldn't load stock items.": "Nie można wczytać pozycji magazynowych.",
    "Couldn't load tech-view pictures.": "Nie można wczytać zdjęć ujęć technicznych.",
    "Status update failed": "Aktualizacja statusu nie powiodła się",
    "Reloading tech-view pictures…": "Ponowne wczytywanie zdjęć…",
    "Configure a shooting method in Settings → Grand Shooting before capturing tech views.": "Skonfiguruj metodę zdjęciową w Ustawienia → Grand Shooting przed wykonaniem ujęć technicznych.",
    "Measurements need a LiDAR device.": "Pomiary wymagają urządzenia z LiDAR.",

    # --- Capture flow ---
    "Envoi…": "Wysyłanie…",
    "Shutter": "Migawka",
    "Photo": "Zdjęcie",
    "Detail": "Szczegół",
    "OCR": "OCR",
    "Measure": "Pomiar",
    "Hide keyboard": "Ukryj klawiaturę",

    # --- Settings: Photo / Features ---
    "Fonctionnalités": "Funkcje",
    "Filename patterns": "Wzorce nazw plików",
    "Désactive l'OCR sur les devices où Vision est lent ou imprécis. Désactive Mesures sur les devices sans LiDAR pour basculer en capture photo simple sous le pattern Measurement.": "Wyłącz OCR na urządzeniach, gdzie Vision działa wolno lub nieprecyzyjnie. Wyłącz Pomiary na urządzeniach bez LiDAR, aby przełączyć się na zwykłe zdjęcie pod wzorcem Measurement.",
    "Mesures": "Pomiary",

    # --- Language picker ---
    "Language": "Język",
    "English": "Angielski",
    "Français": "Francuski",
    "Polski": "Polski",

    # --- Measurement / capture flow ---
    "%@ — %lld point(s)": "%@ — %lld punktów",
    "%@ — point %lld of %lld": "%@ — punkt %lld z %lld",
    "%lld measurements": "%lld pomiarów",
    "%lld object(s) kept": "Zachowano: %lld",
    "%lld point(s)": "%lld punktów",
    "%lld points — tap the image to add more, drag a point to adjust, or move to the next measurement.": "%lld punktów — dotknij zdjęcia, aby dodać kolejne, przeciągnij punkt, aby go przesunąć, lub przejdź do następnego pomiaru.",
    "%lld view(s) expected": "Oczekiwane: %lld ujęć",
    "Account": "Konto",
    "Active zone": "Aktywna strefa",
    "Add a measurement": "Dodaj pomiar",
    "Add another": "Dodaj kolejny",
    "Add another measurement": "Dodaj kolejny pomiar",
    "Add to stock": "Dodaj do magazynu",
    "All measurements captured.": "Wszystkie pomiary wykonane.",
    "All measurements captured. Validate to review.": "Wszystkie pomiary wykonane. Zatwierdź, aby zobaczyć podsumowanie.",
    "All measurements defined under this category will also be removed. This cannot be undone.": "Wszystkie pomiary z tej kategorii również zostaną usunięte. Tej operacji nie można cofnąć.",
    "Already in stock": "Już w magazynie",
    "Attach to a reference": "Powiąż z referencją",
    "Attach to reference": "Powiąż z referencją",
    "Back in warehouse": "Powrót do magazynu",
    "Backend": "Backend",
    "Batch types": "Typy partii",
    "Batches": "Partie",
    "Browse boxes and shelves. Scan a batch barcode to open it.": "Przeglądaj kartony i półki. Zeskanuj kod kreskowy partii, aby ją otworzyć.",
    "Capture": "Wykonaj",
    "Capture behaviour": "Zachowanie aparatu",
    "Capture frame": "Wykonaj ujęcie",
    "Care": "Pielęgnacja",
    "Catalog not loaded": "Katalog nie został załadowany",
    "Categories": "Kategorie",
    "Category": "Kategoria",
    "Category #%lld": "Kategoria #%lld",
    "Category name": "Nazwa kategorii",
    "Category name (e.g. Dress, Shirt, Game box)": "Nazwa kategorii (np. Sukienka, Koszula, Pudełko gry)",
    "Centimeters": "Centymetry",
    "Change status": "Zmień status",
    "Choose a batch first": "Najpierw wybierz partię",
    "Choose a category": "Wybierz kategorię",
    "Choose a measure category": "Wybierz kategorię pomiarową",
    "Clear association": "Usuń powiązanie",
    "Client return": "Zwrot od klienta",
    "Close": "Zamknij",
    "Code": "Kod",
    "Code (barcode)": "Kod (kreskowy)",
    "Code (optional, e.g. ERP / catalog code)": "Kod (opcjonalny, np. ERP / katalog)",
    "Composition": "Skład",
    "Configure your API key in Settings to enable lookups.": "Skonfiguruj klucz API w Ustawieniach, aby umożliwić wyszukiwanie.",
    "Couldn't detect any object": "Nie wykryto żadnego obiektu",
    "Create": "Utwórz",
    "Create a new batch": "Utwórz nową partię",
    "Default status on register": "Domyślny status przy rejestracji",
    "Delete category": "Usuń kategorię",
    "Delete this category?": "Usunąć tę kategorię?",
    "Detected text": "Wykryty tekst",
    "Detecting…": "Wykrywanie…",
    "Disable Z guide": "Wyłącz prowadnicę Z",
    "Distance = sum of the segments between successive points. Minimum 2 points = 1 segment.": "Odległość = suma odcinków między kolejnymi punktami. Minimum 2 punkty = 1 odcinek.",
    "Distant — likely different": "Odległe — prawdopodobnie inne",
    "EAN": "EAN",
    "EAN not found in catalog.": "Nie znaleziono kodu EAN w katalogu.",
    "EAN not in catalog": "Brak EAN w katalogu",
    "Edit batch": "Edytuj partię",
    "Enable Z guide": "Włącz prowadnicę Z",
    "Enabled statuses": "Włączone statusy",
    "Enriched": "Wzbogacony",
    "Environment": "Środowisko",
    "Error": "Błąd",
    "Filter by name": "Filtruj po nazwie",
    "Find a product manually by ref, label, sku or ean.": "Wyszukaj produkt ręcznie po ref, etykiecie, SKU lub EAN.",
    "Grand Shooting": "Grand Shooting",
    "Grand Shooting API (fallback)": "Grand Shooting API (zapasowe)",
    "Grand Shooting category": "Kategoria Grand Shooting",
    "Grand Shooting link": "Powiązanie Grand Shooting",
    "Identity": "Tożsamość",
    "If none of the suggestions fit, define a new category using this capture as the example.": "Jeśli żadna z propozycji nie pasuje, utwórz nową kategorię, używając tego ujęcia jako wzoru.",
    "Ignore": "Pomiń",
    "Inches": "Cale",
    "Inventory": "Inwentaryzacja",
    "Keep": "Zachowaj",
    "Label": "Etykieta",
    "Lay the product flat on a clean surface and frame it in the camera.": "Połóż produkt płasko na czystej powierzchni i wykadruj go w aparacie.",
    "LiDAR": "LiDAR",
    "Link to a Grand Shooting category": "Powiąż z kategorią Grand Shooting",
    "Linked Grand Shooting categories no longer exist": "Powiązane kategorie Grand Shooting już nie istnieją",
    "List the dimensions you want to capture for this category. At capture time you'll place 2 or more points per measurement; the distance is the sum of the segments.": "Wymień wymiary, które chcesz mierzyć w tej kategorii. Podczas pomiaru umieść 2 lub więcej punktów dla każdego — odległość to suma odcinków.",
    "List the dimensions you want to capture. At the next step you'll place the points for each measurement on the test product — the number of points you place becomes the schema for this category.": "Wymień wymiary do uchwycenia. W następnym kroku umieść punkty dla każdego pomiaru na produkcie testowym — liczba punktów stanie się schematem tej kategorii.",
    "Live distance: %@": "Aktualna odległość: %@",
    "Loading shooting methods…": "Wczytywanie metod zdjęciowych…",
    "Look up": "Wyszukaj",
    "Look up a reference and update its stock item status.": "Wyszukaj referencję i zaktualizuj status pozycji magazynowej.",
    "Looking for similar objects…": "Wyszukiwanie podobnych obiektów…",
    "Looking up…": "Wyszukiwanie…",
    "Lookup failed": "Wyszukiwanie nie powiodło się",
    "Lost": "Utracony",
    "Mark as dispatched": "Oznacz jako wysłany",
    "Measure works only on devices with a LiDAR scanner — iPhone Pro / Pro Max and iPad Pro.": "Pomiar działa tylko na urządzeniach z LiDAR — iPhone Pro / Pro Max oraz iPad Pro.",
    "Measurement": "Pomiar",
    "Measurement name (e.g. sleeve)": "Nazwa pomiaru (np. rękaw)",
    "Measurements": "Pomiary",
    "Measures need LiDAR": "Pomiary wymagają LiDAR",
    "Missing": "Brakujący",
    "Mobile backend": "Backend mobilny",
    "Multiple objects detected": "Wykryto wiele obiektów",
    "Name": "Nazwa",
    "Names listed in capture order. At capture time you'll place 2 or more points per measurement.": "Nazwy w kolejności przechwytywania. Podczas pomiaru umieść 2 lub więcej punktów dla każdego.",
    "New batch": "Nowa partia",
    "New category": "Nowa kategoria",
    "New measurement (e.g. sleeve)": "Nowy pomiar (np. rękaw)",
    "Next measurement": "Następny pomiar",
    "No categories yet": "Brak kategorii",
    "No measure category yet": "Brak kategorii pomiarowych",
    "No measurements yet": "Brak pomiarów",
    "No object was found in the frame. Move closer or check the lighting.": "Nie znaleziono obiektu w kadrze. Podejdź bliżej lub sprawdź oświetlenie.",
    "No reference for %@.": "Brak referencji dla %@.",
    "No reference image yet": "Brak zdjęcia referencyjnego",
    "No text detected on this shot.": "Nie wykryto tekstu na tym zdjęciu.",
    "None": "Brak",
    "Not in catalog — will be cleared on next refresh": "Nie ma w katalogu — zostanie wyczyszczone przy następnym odświeżeniu",
    "Notes": "Notatki",
    "Open the Measures tab and create a category that matches this product first.": "Otwórz zakładkę Pomiary i najpierw utwórz kategorię pasującą do tego produktu.",
    "Optional. Linking this category to a Grand Shooting one lets the app cross-check the link at startup and clear it if the GS category disappears.": "Opcjonalnie. Powiązanie tej kategorii z kategorią Grand Shooting pozwala aplikacji sprawdzać powiązanie przy starcie i czyścić je, gdy kategoria GS zniknie.",
    "Optional. Linking this category to a Grand Shooting one lets the app cross-check the link at startup.": "Opcjonalnie. Powiązanie tej kategorii z kategorią Grand Shooting pozwala aplikacji sprawdzać powiązanie przy starcie.",
    "Or enter ref / EAN manually": "Lub wpisz ref / EAN ręcznie",
    "Origin": "Pochodzenie",
    "Password": "Hasło",
    "Pick a shooting method in Settings → Technical views to enable technical-view uploads.": "Wybierz metodę zdjęciową w Ustawienia → Ujęcia techniczne, aby umożliwić przesyłanie zdjęć.",
    "Pick the Grand Shooting catalog category these measurements belong to. The link is saved on the local category for future captures.": "Wybierz kategorię katalogu Grand Shooting, do której należą te pomiary. Powiązanie zostanie zapisane w lokalnej kategorii do przyszłych pomiarów.",
    "Picking": "Wybór",
    "Picks the Grand Shooting shooting method the technical-view uploads are scoped to. The Photo tab is disabled until a method is selected.": "Wybiera metodę zdjęciową Grand Shooting, do której są przypisywane ujęcia techniczne. Zakładka Zdjęcie jest wyłączona, dopóki nie wybierzesz metody.",
    "Pictures": "Zdjęcia",
    "Plausible match": "Możliwe dopasowanie",
    "Point %lld — hold steady, or tap anywhere to lock.": "Punkt %lld — trzymaj nieruchomo lub dotknij ekranu, aby zablokować.",
    "Point %lld of %lld — hold steady, or tap anywhere to lock.": "Punkt %lld z %lld — trzymaj nieruchomo lub dotknij ekranu, aby zablokować.",
    "Point %lld of %lld — hold the device still on the target.": "Punkt %lld z %lld — trzymaj urządzenie nieruchomo na celu.",
    "Points": "Punkty",
    "Prepare": "Przygotuj",
    "Rank %lld": "Pozycja %lld",
    "Reading…": "Wczytywanie…",
    "Receive": "Odbierz",
    "Reference": "Referencja",
    "Reference (ref)": "Referencja (ref)",
    "Reference photo": "Zdjęcie referencyjne",
    "Refresh catalog": "Odśwież katalog",
    "Refresh list": "Odśwież listę",
    "Register products": "Zarejestruj produkty",
    "Remove last measurement": "Usuń ostatni pomiar",
    "Restrictions": "Ograniczenia",
    "Save category": "Zapisz kategorię",
    "Save measurements": "Zapisz pomiary",
    "Saved": "Zapisano",
    "Saved to %@": "Zapisano do %@",
    "Saving…": "Zapisywanie…",
    "Scan an item to add it to a batch in your stock.": "Zeskanuj produkt, aby dodać go do partii w magazynie.",
    "Scan lookup": "Wyszukiwanie skanem",
    "Scan or pick a reference to save these measurements as `extra.measures` on Grand Shooting.": "Zeskanuj lub wybierz referencję, aby zapisać te pomiary jako `extra.measures` w Grand Shooting.",
    "Scan products": "Skanuj produkty",
    "Scan reference": "Skanuj referencję",
    "Search by name or code": "Szukaj po nazwie lub kodzie",
    "Segments are reprojected onto the original photo from the LiDAR world coordinates captured during placement.": "Odcinki są rzutowane na oryginalne zdjęcie z współrzędnych LiDAR zebranych podczas umieszczania punktów.",
    "Select a batch": "Wybierz partię",
    "Select batch": "Wybierz partię",
    "Sent": "Wysłano",
    "Sent from warehouse": "Wysłano z magazynu",
    "Shard": "Shard",
    "Shooting method": "Metoda zdjęciowa",
    "Shooting method not set": "Nie wybrano metody zdjęciowej",
    "Sign in to start scanning": "Zaloguj się, aby rozpocząć skanowanie",
    "Sign in with dev credentials": "Zaloguj się danymi dev",
    "Sign in with Grand Shooting": "Zaloguj się przez Grand Shooting",
    "Skip": "Pomiń",
    "Sorted by visual similarity. The closer to the top, the better the match.": "Posortowane według podobieństwa wizualnego. Im wyżej, tym lepsze dopasowanie.",
    "Standards": "Normy",
    "Start a measurement to capture an object. The first capture creates a category; subsequent ones are recognised automatically.": "Rozpocznij pomiar, aby uchwycić obiekt. Pierwsze ujęcie tworzy kategorię, kolejne są rozpoznawane automatycznie.",
    "Strong match": "Mocne dopasowanie",
    "Tap any object you don't want to measure to exclude it. Only the included objects are used for the measurement.": "Dotknij obiektu, którego nie chcesz mierzyć, aby go wykluczyć. Tylko dołączone obiekty są używane do pomiaru.",
    "Tap the image to place points. A measurement needs at least 2.": "Dotknij zdjęcia, aby umieścić punkty. Pomiar wymaga co najmniej 2.",
    "Tap to view details": "Dotknij, aby zobaczyć szczegóły",
    "Technical views": "Ujęcia techniczne",
    "The captured photo will become the category's illustration after you've taken the test measurements.": "Wykonane zdjęcie stanie się ilustracją kategorii po wykonaniu pomiarów testowych.",
    "The code lets you link this category to your internal coding system. It's free-form and optional.": "Kod pozwala powiązać tę kategorię z wewnętrznym systemem kodowania. Pole jest dowolne i opcjonalne.",
    "The Grand Shooting catalog hasn't been pulled yet. Open Settings → Workflow → Refresh catalog.": "Katalog Grand Shooting nie został jeszcze pobrany. Otwórz Ustawienia → Workflow → Odśwież katalog.",
    "This image becomes the visual reference for this category. Future captures matching it will suggest this category automatically.": "To zdjęcie staje się wizualną referencją kategorii. Przyszłe ujęcia podobne do niego będą automatycznie sugerować tę kategorię.",
    "Transfer": "Transfer",
    "Type": "Typ",
    "Undo": "Cofnij",
    "Unit": "Jednostka",
    "Unit used when capturing dimensions in the Measures tab and storing them on the reference.": "Jednostka używana podczas pomiarów w zakładce Pomiary i zapisywana w referencji.",
    "Username": "Nazwa użytkownika",
    "Visual reference used to suggest this category on future captures.": "Wizualna referencja używana do sugerowania tej kategorii przy kolejnych pomiarach.",
    "Warehouse stock": "Stan magazynu",
    "Will save these measurements as `extra.measures` on %@.": "Zapisze te pomiary jako `extra.measures` w %@.",
    "Workflow": "Workflow",
    "Zone": "Strefa",
}


def main() -> None:
    with XCSTRINGS.open() as f:
        catalog = json.load(f)

    strings = catalog.get("strings", {})
    added = 0
    updated = 0
    skipped = 0
    no_dict_term = 0

    for key, entry in strings.items():
        locs = entry.setdefault("localizations", {})
        # Only translate keys that already have a FR translation —
        # those are the ones surfaced through xcstrings today.
        if "fr" not in locs:
            skipped += 1
            continue
        pl_value = PL.get(key)
        if pl_value is None:
            # No dictionary entry yet. Carry over the FR text so
            # the UI never falls back to English silently — but
            # mark the state as `needs_review` so the next person
            # editing translations spots it.
            fr_value = locs["fr"]["stringUnit"]["value"]
            pl_value = fr_value
            state = "needs_review"
            no_dict_term += 1
        else:
            state = "translated"
        had = "pl" in locs
        locs["pl"] = {
            "stringUnit": {
                "state": state,
                "value": pl_value
            }
        }
        if had:
            updated += 1
        else:
            added += 1

    with XCSTRINGS.open("w") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"added={added} updated={updated} skipped_no_fr={skipped} needs_review={no_dict_term}")


if __name__ == "__main__":
    main()

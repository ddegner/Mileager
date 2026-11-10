#!/usr/bin/env python3
"""Build the App Store screenshot seed catalog.

Fetches road-following driving routes from OSRM for every seed trip and writes
`MileageTracker/Resources/ScreenshotSeeds/AppStoreScreenshotSeeds.json`, keyed
by App Store locale. The app loads one locale's slice when launched with
`--seed-app-store-screenshot-data --screenshot-locale=<id>`.

OSRM returns precision-5 polylines, the same format MileageTracker's
EncodedPolyline uses, so the geometry is embedded verbatim as the trip's
routePolyline. Distances/durations come from OSRM so the displayed mileage
matches the drawn line. `overview=full` keeps short urban routes hugging the
street grid in the card map thumbnails (simplified geometry draws visibly
straight diagonals); the resulting JSON is still well under a megabyte.

The JSON is committed; OSM edits change polylines between runs, so regenerate
rarely and deliberately:

    python3 scripts/generate_screenshot_routes.py               # all locales
    python3 scripts/generate_screenshot_routes.py --locale de-DE  # one locale,
                                                  # merged into the existing file

Every place is a real, publicly known address (never fake placeholders, never
the developer's own locations). Persona: freelance photographer — studio,
client offices, print/camera shops, galleries, one regional day trip.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time
import urllib.request

OSRM = (
    "https://router.project-osrm.org/route/v1/driving/{c0};{c1}"
    "?overview=full&geometries=polyline"
)
OUTPUT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "MileageTracker/Resources/ScreenshotSeeds/AppStoreScreenshotSeeds.json"
)

# ---------------------------------------------------------------------------
# Locale catalogs.
#
# Trip skeleton (keep identical across locales so every locale's list looks
# the same), shaped around the two screens the capture photographs:
#
#   June  9 — 2 filed + a 7-drive Needs Review queue, every one carrying an
#             AI-suggestion fixture. This is card 1, so the queue leads and
#             closes with a long location day and keeps one personal
#             suggestion for the red preview line.
#   May   9 — fully classified with three location days and four parking
#             fees. This is card 2: the most recently closed month, the one
#             a user would actually export, so its total has to look like a
#             working month rather than a week of errands.
#   Apr 3 · Mar 2 · Feb 2 — history, so the Mailboxes root has real months
#             under the current one.
#
# Keep the long day trips out of the oldest months: nothing below May is ever
# photographed, and burying the big distances there is what made the earlier
# skeleton's cards read as a string of two-mile errands.
#
# `suggestion` mirrors what the Foundation Models provider produces on device:
# advisory classification + preset-vocabulary purpose + one calendar-event
# evidence title. The UI test provider replays these verbatim.
# ---------------------------------------------------------------------------

LOCALES: dict[str, dict] = {
    "en-US": {
        "mileageRate": {"amountPerUnit": 0.725, "unit": "miles"},
        "currencyCode": "USD",
        "businessPurposePresets": ["Photo shoot", "Client meeting", "Supplies"],
        # Columbus, OH — real drivable places.
        "places": {
            "studio": (39.9573, -83.0284),          # 400 West Rich artist studios
            "ohioStatehouse": (39.9612, -82.9988),
            "columbusMuseum": (39.9644, -82.9876),
            "midwestPhoto": (40.0269, -83.0125),    # real Columbus camera store
            "northMarket": (39.9719, -83.0040),
            "franklinPark": (39.9655, -82.9539),
            "ohioStadium": (40.0017, -83.0197),
            "eastonTownCenter": (40.0503, -82.9151),
            "cosi": (39.9594, -83.0066),
            "hockingHills": (39.4343, -82.5419),
            "dawesArboretum": (39.9814, -82.4132),
            "wexnerCenter": (39.9971, -83.0086),
        },
        "labels": {
            "studio": "400 W Rich St, Columbus, OH 43215, United States",
            "ohioStatehouse": "Ohio Statehouse, 1 Capitol Square, Columbus, OH 43215, United States",
            "columbusMuseum": "Columbus Museum of Art, 480 E Broad St, Columbus, OH 43215, United States",
            "midwestPhoto": "Midwest Photo, 3313 N High St, Columbus, OH 43202, United States",
            "northMarket": "North Market, 59 Spruce St, Columbus, OH 43215, United States",
            "franklinPark": "Franklin Park Conservatory, 1777 E Broad St, Columbus, OH 43203, United States",
            "ohioStadium": "Ohio Stadium, 411 Woody Hayes Dr, Columbus, OH 43210, United States",
            "eastonTownCenter": "Easton Town Center, 160 Easton Town Center, Columbus, OH 43219, United States",
            "cosi": "COSI, 333 W Broad St, Columbus, OH 43215, United States",
            "hockingHills": "Hocking Hills State Park, 19852 OH-664, Logan, OH 43138, United States",
            "dawesArboretum": "The Dawes Arboretum, 7770 Jacksontown Rd SE, Newark, OH 43056, United States",
            "wexnerCenter": "Wexner Center for the Arts, 1871 N High St, Columbus, OH 43210, United States",
        },
        "trips": [
            # June 2026 — the newest month, and the one that fills Needs Review.
            # The two resolved drives sit above the queue: a real current month
            # is partly filed, and they keep the month screen from reading as
            # "nothing has ever been reviewed".
            dict(o="studio", d="midwestPhoto", cls="business", purpose="Supplies",
                 notes="Test prints", tolls=0, parking=0, m=6, day=26, h=10, mn=30),
            dict(o="columbusMuseum", d="studio", cls="business", purpose="Client meeting",
                 notes="Frame check", tolls=0, parking=8.00, m=6, day=25, h=14, mn=20),
            # Needs Review (card 1), newest first. Every one carries a suggestion
            # fixture, and the queue leads and closes with a long location day so
            # the card is not a screen of errands.
            dict(o="studio", d="hockingHills", cls=None, purpose=None,
                 notes="Location day one", tolls=0, parking=0,
                 m=6, day=24, h=8, mn=10,
                 suggestion=dict(classification="business",
                                 businessPurpose="Photo shoot",
                                 calendarEventTitle="Fall issue")),
            dict(o="cosi", d="eastonTownCenter", cls=None, purpose=None,
                 notes="Editorial pitch", tolls=0, parking=0,
                 m=6, day=22, h=16, mn=35,
                 suggestion=dict(classification="business",
                                 businessPurpose="Client meeting",
                                 calendarEventTitle="Art buyer")),
            dict(o="northMarket", d="midwestPhoto", cls=None, purpose=None,
                 notes="Backdrop paper and batteries", tolls=0, parking=0,
                 m=6, day=19, h=11, mn=20,
                 suggestion=dict(classification="business",
                                 businessPurpose="Supplies",
                                 calendarEventTitle="Print pickup")),
            dict(o="cosi", d="ohioStadium", cls=None, purpose=None,
                 notes="Team photo day", tolls=0, parking=0,
                 m=6, day=17, h=9, mn=5,
                 suggestion=dict(classification="business",
                                 businessPurpose="Photo shoot",
                                 calendarEventTitle="Team photo")),
            # The one personal suggestion: it renders the preview line red
            # instead of green, which is the whole point of tinting that line.
            dict(o="eastonTownCenter", d="franklinPark", cls=None, purpose=None,
                 notes="Personal stop", tolls=0, parking=0,
                 m=6, day=15, h=18, mn=40,
                 suggestion=dict(classification="personal",
                                 businessPurpose=None,
                                 calendarEventTitle="Yoga class")),
            dict(o="studio", d="ohioStatehouse", cls=None, purpose=None,
                 notes="Morning assignment", tolls=0, parking=0,
                 m=6, day=12, h=13, mn=15,
                 suggestion=dict(classification="business",
                                 businessPurpose="Client meeting",
                                 calendarEventTitle="Print drop")),
            dict(o="studio", d="dawesArboretum", cls=None, purpose=None,
                 notes="Magazine feature scouting", tolls=0, parking=0,
                 m=6, day=10, h=7, mn=45,
                 suggestion=dict(classification="business",
                                 businessPurpose="Photo shoot",
                                 calendarEventTitle="Site visit")),
            # May 2026 — the closed month on card 2. Fully classified, three
            # location days, and enough parking to make the fee column real.
            #
            # NOT ONE of these origin/destination pairs may repeat a June pair
            # above. Cards 1 and 2 sit side by side in the App Store gallery,
            # and a shared pair draws a pixel-identical route thumbnail on both
            # — the two screenshots then read as the same list photographed
            # twice. The 26 May pair is deliberately an out-and-back on one
            # day, which is what a location day actually looks like and reads
            # as a round trip rather than a duplicated row.
            dict(o="northMarket", d="hockingHills", cls="business", purpose="Photo shoot",
                 notes="Location day one", tolls=0, parking=0, m=5, day=28, h=7, mn=50),
            dict(o="northMarket", d="dawesArboretum", cls="business", purpose="Photo shoot",
                 notes="Golden hour scouting", tolls=0, parking=0, m=5, day=26, h=12, mn=30),
            dict(o="dawesArboretum", d="studio", cls="business", purpose="Photo shoot",
                 notes="Magazine feature scouting", tolls=0, parking=0, m=5, day=26, h=19, mn=40),
            dict(o="studio", d="eastonTownCenter", cls="business", purpose="Client meeting",
                 notes="Editorial pitch", tolls=0, parking=3.00, m=5, day=19, h=10, mn=5),
            dict(o="ohioStatehouse", d="eastonTownCenter", cls="business", purpose="Client meeting",
                 notes="Layout sign-off", tolls=0, parking=6.00, m=5, day=14, h=9, mn=40),
            dict(o="ohioStadium", d="columbusMuseum", cls="business", purpose="Client meeting",
                 notes="Frame check", tolls=0, parking=8.00, m=5, day=12, h=11, mn=15),
            dict(o="columbusMuseum", d="midwestPhoto", cls="business", purpose="Supplies",
                 notes="Exhibition prints", tolls=0, parking=0, m=5, day=8, h=13, mn=45),
            dict(o="studio", d="columbusMuseum", cls="business", purpose="Photo shoot",
                 notes="Portrait session", tolls=0, parking=10.00, m=5, day=6, h=8, mn=15),
            dict(o="studio", d="franklinPark", cls="personal", purpose=None,
                 notes="Personal stop", tolls=0, parking=0, m=5, day=4, h=18, mn=20),
            # April 2026.
            dict(o="studio", d="ohioStadium", cls="business", purpose="Photo shoot",
                 notes="Team photo day", tolls=0, parking=12.00, m=4, day=23, h=9, mn=25),
            dict(o="cosi", d="northMarket", cls="business", purpose="Client meeting",
                 notes="Print delivery and walkthrough", tolls=0, parking=5.75, m=4, day=16, h=16, mn=40),
            dict(o="midwestPhoto", d="studio", cls="business", purpose="Supplies",
                 notes="Test prints", tolls=0, parking=0, m=4, day=9, h=14, mn=0),
            # March 2026.
            dict(o="studio", d="midwestPhoto", cls="business", purpose="Supplies",
                 notes="Backdrop paper and batteries", tolls=0, parking=0, m=3, day=26, h=11, mn=5),
            dict(o="studio", d="ohioStatehouse", cls="business", purpose="Photo shoot",
                 notes="Morning assignment", tolls=0, parking=0, m=3, day=12, h=8, mn=18),
            # February 2026.
            dict(o="franklinPark", d="wexnerCenter", cls="business", purpose="Client meeting",
                 notes="Needs client label", tolls=0, parking=0, m=2, day=19, h=14, mn=10),
            dict(o="columbusMuseum", d="midwestPhoto", cls="business", purpose="Supplies",
                 notes="Exhibition prints", tolls=0, parking=0, m=2, day=5, h=13, mn=45),
        ],
    },
}

# ---------------------------------------------------------------------------
# Role-based locales (es-ES Valencia, es-MX Guadalajara, fr-FR Lyon,
# fr-CA Montréal, de-DE Munich). All share ROLE_TRIPS (same 25-trip
# composition as en-US); each locale supplies web-verified real places by role
# plus translated strings, a per-km mileage rate, and a currency fee scale.
# Translation voice matches app-store-assets/metadata/: es informal (tú),
# fr formal (vous), de formal (Sie/Ihr); es-MX (viajes/reportes/impresiones)
# vs es-ES (trayectos/informes/copias); fr-CA (déplacements/épreuves) vs
# fr-FR (trajets/tirages).
# ---------------------------------------------------------------------------

ROLE_TRIPS = [
    # June — two filed drives, then the seven-drive Needs Review queue.
    dict(o="studio", d="cameraStore", cls="business", purpose="supplies", note="testPrints", parking=0, m=6, day=26, h=10, mn=30),
    dict(o="museum", d="studio", cls="business", purpose="clientMeeting", note="frameCheck", parking=8.00, m=6, day=25, h=14, mn=20),
    dict(o="studio", d="dayTrip1", cls=None, note="locationDay1", parking=0, m=6, day=24, h=8, mn=10, sug=("photoShoot", "event1")),
    dict(o="culture", d="mall", cls=None, note="editorialPitch", parking=0, m=6, day=22, h=16, mn=35, sug=("clientMeeting", "event2")),
    dict(o="market", d="cameraStore", cls=None, note="backdropPaper", parking=0, m=6, day=19, h=11, mn=20, sug=("supplies", "event3")),
    dict(o="culture", d="venue", cls=None, note="teamPhoto", parking=0, m=6, day=17, h=9, mn=5, sug=("photoShoot", "event4")),
    dict(o="mall", d="park", cls=None, note="personalStop", parking=0, m=6, day=15, h=18, mn=40, sug=(None, "event5", "personal")),
    dict(o="studio", d="landmark", cls=None, note="morningAssignment", parking=0, m=6, day=12, h=13, mn=15, sug=("clientMeeting", "event6")),
    dict(o="studio", d="dayTrip2", cls=None, note="magazineScouting", parking=0, m=6, day=10, h=7, mn=45, sug=("photoShoot", "event7")),
    # May — the closed month on card 2. No pair here may repeat a June pair
    # above: cards 1 and 2 sit side by side, and a shared pair draws the same
    # route thumbnail on both. 26 May is one out-and-back location day.
    dict(o="market", d="dayTrip1", cls="business", purpose="photoShoot", note="locationDay1", parking=0, m=5, day=28, h=7, mn=50),
    dict(o="market", d="dayTrip2", cls="business", purpose="photoShoot", note="goldenHour", parking=0, m=5, day=26, h=12, mn=30),
    dict(o="dayTrip2", d="studio", cls="business", purpose="photoShoot", note="magazineScouting", parking=0, m=5, day=26, h=19, mn=40),
    dict(o="studio", d="mall", cls="business", purpose="clientMeeting", note="editorialPitch", parking=3.00, m=5, day=19, h=10, mn=5),
    dict(o="landmark", d="mall", cls="business", purpose="clientMeeting", note="layoutSignoff", parking=6.00, m=5, day=14, h=9, mn=40),
    dict(o="venue", d="museum", cls="business", purpose="clientMeeting", note="frameCheck", parking=8.00, m=5, day=12, h=11, mn=15),
    dict(o="museum", d="cameraStore", cls="business", purpose="supplies", note="exhibitionPrints", parking=0, m=5, day=8, h=13, mn=45),
    dict(o="studio", d="museum", cls="business", purpose="photoShoot", note="portraitSession", parking=10.00, m=5, day=6, h=8, mn=15),
    dict(o="studio", d="park", cls="personal", note="personalStop", parking=0, m=5, day=4, h=18, mn=20),
    # April.
    dict(o="studio", d="venue", cls="business", purpose="photoShoot", note="teamPhoto", parking=12.00, m=4, day=23, h=9, mn=25),
    dict(o="culture", d="market", cls="business", purpose="clientMeeting", note="printDelivery", parking=5.75, m=4, day=16, h=16, mn=40),
    dict(o="cameraStore", d="studio", cls="business", purpose="supplies", note="testPrints", parking=0, m=4, day=9, h=14, mn=0),
    # March.
    dict(o="studio", d="cameraStore", cls="business", purpose="supplies", note="backdropPaper", parking=0, m=3, day=26, h=11, mn=5),
    dict(o="studio", d="landmark", cls="business", purpose="photoShoot", note="morningAssignment", parking=0, m=3, day=12, h=8, mn=18),
    # February.
    dict(o="park", d="gallery", cls="business", purpose="clientMeeting", note="needsLabel", parking=0, m=2, day=19, h=14, mn=10),
    dict(o="museum", d="cameraStore", cls="business", purpose="supplies", note="exhibitionPrints", parking=0, m=2, day=5, h=13, mn=45),
]

STRINGS = {
    "es-ES": {
        "photoShoot": "Sesión de fotos", "clientMeeting": "Reunión con cliente", "supplies": "Material",
        "morningAssignment": "Encargo de la mañana", "needsLabel": "Falta etiqueta de cliente",
        "teamPhoto": "Día de foto de equipo", "printDelivery": "Entrega de copias y visita",
        "backdropPaper": "Papel de fondo y pilas", "personalStop": "Parada personal",
        "editorialPitch": "Propuesta editorial", "exhibitionPrints": "Copias para la exposición",
        "locationDay1": "Primer día de localización", "goldenHour": "Exploración a la hora dorada",
        "magazineScouting": "Localización para reportaje", "frameCheck": "Revisión de encuadre",
        "layoutSignoff": "Aprobación de maqueta", "portraitSession": "Sesión de retrato",
        "testPrints": "Copias de prueba",
        "event1": "Portada", "event2": "Agencia", "event3": "Recoger copias",
        # "Reunión con cliente" is 19 characters before the separator, so the
        # Spanish event titles have to stay terse or the preview line elides.
        "event4": "Equipo", "event5": "Clase de yoga", "event6": "Entrega",
        "event7": "Exteriores",
    },
    "es-MX": {
        "photoShoot": "Sesión de fotos", "clientMeeting": "Reunión con cliente", "supplies": "Material",
        "morningAssignment": "Encargo de la mañana", "needsLabel": "Falta etiqueta de cliente",
        "teamPhoto": "Día de foto de equipo", "printDelivery": "Entrega de impresiones y recorrido",
        "backdropPaper": "Papel de fondo y pilas", "personalStop": "Parada personal",
        "editorialPitch": "Propuesta editorial", "exhibitionPrints": "Impresiones para la exposición",
        "locationDay1": "Primer día de locación", "goldenHour": "Exploración en la hora dorada",
        "magazineScouting": "Locación para reportaje", "frameCheck": "Revisión de encuadre",
        "layoutSignoff": "Aprobación del diseño", "portraitSession": "Sesión de retrato",
        "testPrints": "Impresiones de prueba",
        "event1": "Portada", "event2": "Agencia", "event3": "Recoger fotos",
        "event4": "Equipo", "event5": "Clase de yoga", "event6": "Entrega",
        "event7": "Locación",
    },
    "fr-FR": {
        "photoShoot": "Séance photo", "clientMeeting": "Rendez-vous client", "supplies": "Fournitures",
        "morningAssignment": "Reportage du matin", "needsLabel": "À étiqueter pour le client",
        "teamPhoto": "Photo d'équipe", "printDelivery": "Livraison de tirages et visite",
        "backdropPaper": "Fond papier et piles", "personalStop": "Arrêt personnel",
        "editorialPitch": "Proposition éditoriale", "exhibitionPrints": "Tirages pour l'exposition",
        "locationDay1": "Première journée de prises de vue", "goldenHour": "Repérage à l'heure dorée",
        "magazineScouting": "Repérage pour un reportage", "frameCheck": "Vérification du cadrage",
        "layoutSignoff": "Validation de la maquette", "portraitSession": "Séance portrait",
        "testPrints": "Tirages d'essai",
        "event1": "Couverture", "event2": "Agence", "event3": "Retrait tirages",
        "event4": "Équipe", "event5": "Cours de yoga", "event6": "Remise",
        "event7": "Repérage",
    },
    "fr-CA": {
        "photoShoot": "Séance photo", "clientMeeting": "Rencontre client", "supplies": "Matériel",
        "morningAssignment": "Reportage du matin", "needsLabel": "À classer pour le client",
        "teamPhoto": "Photo d'équipe", "printDelivery": "Livraison d'épreuves et visite",
        "backdropPaper": "Toile de fond et piles", "personalStop": "Arrêt personnel",
        "editorialPitch": "Proposition éditoriale", "exhibitionPrints": "Épreuves pour l'exposition",
        "locationDay1": "Première journée de prises de vue", "goldenHour": "Repérage à l'heure dorée",
        "magazineScouting": "Repérage pour un reportage", "frameCheck": "Vérification du cadrage",
        "layoutSignoff": "Approbation de la maquette", "portraitSession": "Séance portrait",
        "testPrints": "Épreuves d'essai",
        "event1": "Urbania", "event2": "Agence", "event3": "Retrait épreuves",
        "event4": "Équipe", "event5": "Cours de yoga", "event6": "Remise",
        "event7": "Repérage",
    },
    "de-DE": {
        "photoShoot": "Fototermin", "clientMeeting": "Kundentermin", "supplies": "Material",
        "morningAssignment": "Auftrag am Morgen", "needsLabel": "Kundenzuordnung fehlt",
        "teamPhoto": "Teamfoto-Termin", "printDelivery": "Abzüge liefern und Rundgang",
        "backdropPaper": "Hintergrundpapier und Akkus", "personalStop": "Privater Halt",
        "editorialPitch": "Editorial-Pitch", "exhibitionPrints": "Abzüge für die Ausstellung",
        "locationDay1": "Erster Tag der Aufnahmen", "goldenHour": "Location-Suche zur goldenen Stunde",
        "magazineScouting": "Location-Suche für Reportage", "frameCheck": "Bildausschnitt prüfen",
        "layoutSignoff": "Layout-Freigabe", "portraitSession": "Porträttermin",
        "testPrints": "Testabzüge",
        "event1": "Titelbild", "event2": "Agentur", "event3": "Abzüge abholen",
        "event4": "Teamfoto", "event5": "Yogakurs", "event6": "Abgabe",
        "event7": "Motivsuche",
    },
}

# Per-km mileage rate + currency + fee scale relative to the en-US USD amounts.
LOCALE_META = {
    "es-ES": {"rate": 0.26, "currency": "EUR", "feeScale": 1.0},
    "es-MX": {"rate": 2.50, "currency": "MXN", "feeScale": 18.0},
    "fr-FR": {"rate": 0.529, "currency": "EUR", "feeScale": 1.0},
    "fr-CA": {"rate": 0.72, "currency": "CAD", "feeScale": 1.0},
    "de-DE": {"rate": 0.30, "currency": "EUR", "feeScale": 1.0},
}

# Web-verified real places by role (name/address/coords). Coordinates sit on or
# beside a drivable road so OSRM can snap. See scripts research notes.
RESEARCH = {
    "es-ES": {
        "studio": {"name": "Estudio Russafa", "address": "Carrer de Sueca 47, 46006 València, Spain", "lat": 39.4609, "lon": -0.3746},
        "landmark": {"name": "Torres de Serranos", "address": "Plaça dels Furs, 46003 València, Spain", "lat": 39.4792, "lon": -0.3760},
        "museum": {"name": "Museu de Belles Arts de València", "address": "Carrer de Sant Pius V 9, 46010 València, Spain", "lat": 39.4783, "lon": -0.3701},
        "cameraStore": {"name": "Fotopro", "address": "Carrer de Castelló 2, 46004 València, Spain", "lat": 39.4699, "lon": -0.3712},
        "market": {"name": "Mercat Central de València", "address": "Plaça de la Ciutat de Bruges, 46001 València, Spain", "lat": 39.4735, "lon": -0.3789},
        "park": {"name": "Jardí del Túria", "address": "Passeig de la Petxina, 46008 València, Spain", "lat": 39.4776, "lon": -0.3872},
        "venue": {"name": "Estadi de Mestalla", "address": "Avinguda de Suècia, 46010 València, Spain", "lat": 39.4745, "lon": -0.3581},
        "mall": {"name": "El Corte Inglés Colón", "address": "Carrer de Colón 27, 46004 València, Spain", "lat": 39.4692, "lon": -0.3739},
        "culture": {"name": "Ciutat de les Arts i les Ciències", "address": "Av. del Professor López Piñero 7, 46013 València, Spain", "lat": 39.4545, "lon": -0.3527},
        "dayTrip1": {"name": "Castell de Xàtiva", "address": "Carretera del Castell, 46800 Xàtiva, València, Spain", "lat": 38.9840, "lon": -0.5170},
        "dayTrip2": {"name": "Castell de Sagunt", "address": "Carrer del Castell, 46500 Sagunt, València, Spain", "lat": 39.6785, "lon": -0.2793},
        "gallery": {"name": "Bombas Gens Centre d'Art", "address": "Avinguda de Burjassot 54, 46009 València, Spain", "lat": 39.4854, "lon": -0.3862},
    },
    "es-MX": {
        "studio": {"name": "Estudio Chapultepec", "address": "Av. Chapultepec Sur 480, Americana, 44160 Guadalajara, Jal., Mexico", "lat": 20.6718, "lon": -103.3667},
        "landmark": {"name": "Teatro Degollado", "address": "Calle Degollado s/n, Centro, 44100 Guadalajara, Jal., Mexico", "lat": 20.6770, "lon": -103.3446},
        "museum": {"name": "MUSA Museo de las Artes", "address": "Av. Juárez 975, Centro, 44100 Guadalajara, Jal., Mexico", "lat": 20.6746, "lon": -103.3573},
        "cameraStore": {"name": "Cámara 21", "address": "Av. Ignacio L. Vallarta 1490, Americana, 44160 Guadalajara, Jal., Mexico", "lat": 20.6743, "lon": -103.3689},
        "market": {"name": "Mercado Libertad", "address": "Calz. Independencia Sur 52, San Juan de Dios, 44360 Guadalajara, Jal., Mexico", "lat": 20.6767, "lon": -103.3378},
        "park": {"name": "Parque Agua Azul", "address": "Calz. Independencia Sur 973, Centro, 44100 Guadalajara, Jal., Mexico", "lat": 20.6589, "lon": -103.3497},
        "venue": {"name": "Estadio Akron", "address": "Av. Circuito JVC 2800, El Bajío, 45014 Zapopan, Jal., Mexico", "lat": 20.6818, "lon": -103.4626},
        "mall": {"name": "Andares", "address": "Blvd. Puerta de Hierro 4965, Puerta de Hierro, 45116 Zapopan, Jal., Mexico", "lat": 20.7114, "lon": -103.4130},
        "culture": {"name": "Hospicio Cabañas", "address": "Calle Cabañas 8, Las Fresas, 44360 Guadalajara, Jal., Mexico", "lat": 20.6769, "lon": -103.3376},
        "dayTrip1": {"name": "Tequila, Jalisco", "address": "C. Albino Rojas 16, El Rastro, 46400 Tequila, Jal., Mexico", "lat": 20.8849, "lon": -103.8390},
        "dayTrip2": {"name": "Ajijic, Lago de Chapala", "address": "Calle Colón 1, Centro, 45920 Ajijic, Jal., Mexico", "lat": 20.2997, "lon": -103.2637},
        "gallery": {"name": "Galería Curro", "address": "C. Andrés Terán 726, Santa Teresita, 44600 Guadalajara, Jal., Mexico", "lat": 20.6835, "lon": -103.3706},
    },
    "fr-FR": {
        "studio": {"name": "Studio Croix-Rousse", "address": "16 Rue des Tables Claudiennes, 69001 Lyon, France", "lat": 45.7702, "lon": 4.8330},
        "landmark": {"name": "Basilique Notre-Dame de Fourvière", "address": "8 Place de Fourvière, 69005 Lyon, France", "lat": 45.7624, "lon": 4.8224},
        "museum": {"name": "Musée des Beaux-Arts de Lyon", "address": "20 Place des Terreaux, 69001 Lyon, France", "lat": 45.7668, "lon": 4.8336},
        "cameraStore": {"name": "Central Photo Lyon", "address": "22 Rue de l'Algérie, 69001 Lyon, France", "lat": 45.7676, "lon": 4.8300},
        "market": {"name": "Les Halles de Lyon Paul Bocuse", "address": "102 Cours Lafayette, 69003 Lyon, France", "lat": 45.7626, "lon": 4.8523},
        "park": {"name": "Parc de la Tête d'Or", "address": "Place Général Leclerc, 69006 Lyon, France", "lat": 45.7772, "lon": 4.8524},
        "venue": {"name": "Halle Tony Garnier", "address": "20 Place des Docteurs Mérieux, 69007 Lyon, France", "lat": 45.7299, "lon": 4.8250},
        "mall": {"name": "Westfield La Part-Dieu", "address": "17 Rue du Docteur Bouchut, 69003 Lyon, France", "lat": 45.7609, "lon": 4.8556},
        "culture": {"name": "Musée des Confluences", "address": "86 Quai Perrache, 69002 Lyon, France", "lat": 45.7337, "lon": 4.8181},
        "dayTrip1": {"name": "Cité médiévale de Pérouges", "address": "Place du Tilleul, 01800 Pérouges, France", "lat": 45.9073, "lon": 5.1727},
        "dayTrip2": {"name": "Temple d'Auguste et de Livie", "address": "2 Place du Palais, 38200 Vienne, France", "lat": 45.5255, "lon": 4.8742},
        "gallery": {"name": "macLYON", "address": "81 Quai Charles de Gaulle, 69006 Lyon, France", "lat": 45.7853, "lon": 4.8536},
    },
    "fr-CA": {
        "studio": {"name": "Studio Mile End", "address": "5333 Boul. Saint-Laurent, Montréal, QC H2T 1S5, Canada", "lat": 45.5249, "lon": -73.5964},
        "landmark": {"name": "Oratoire Saint-Joseph", "address": "3800 Ch. Queen-Mary, Montréal, QC H3V 1H6, Canada", "lat": 45.4922, "lon": -73.6169},
        "museum": {"name": "Musée des beaux-arts de Montréal", "address": "1380 Rue Sherbrooke O, Montréal, QC H3G 1J5, Canada", "lat": 45.4985, "lon": -73.5794},
        "cameraStore": {"name": "Camtec Photo", "address": "26 Rue Notre-Dame E, Montréal, QC H2Y 1B9, Canada", "lat": 45.5075, "lon": -73.5548},
        "market": {"name": "Marché Jean-Talon", "address": "7070 Av. Henri-Julien, Montréal, QC H2S 3S3, Canada", "lat": 45.5361, "lon": -73.6150},
        "park": {"name": "Parc La Fontaine", "address": "3819 Av. Calixa-Lavallée, Montréal, QC H2H 1P4, Canada", "lat": 45.5250, "lon": -73.5695},
        "venue": {"name": "Stade olympique de Montréal", "address": "4141 Av. Pierre-De Coubertin, Montréal, QC H1V 3N7, Canada", "lat": 45.5578, "lon": -73.5515},
        "mall": {"name": "Centre Eaton de Montréal", "address": "705 Rue Sainte-Catherine O, Montréal, QC H3B 4G5, Canada", "lat": 45.5040, "lon": -73.5714},
        "culture": {"name": "Place des Arts", "address": "175 Rue Sainte-Catherine O, Montréal, QC H2X 3X5, Canada", "lat": 45.5083, "lon": -73.5665},
        "dayTrip1": {"name": "Village de Tremblant", "address": "151 Ch. du Curé-Deslauriers, Mont-Tremblant, QC J8E 1C9, Canada", "lat": 46.2100, "lon": -74.5870},
        "dayTrip2": {"name": "Saint-Sauveur", "address": "205 Rue Principale, Saint-Sauveur, QC J0R 1R0, Canada", "lat": 45.8959, "lon": -74.1576},
        "gallery": {"name": "Fonderie Darling", "address": "745 Rue Ottawa, Montréal, QC H3C 1R8, Canada", "lat": 45.4942, "lon": -73.5568},
    },
    "de-DE": {
        "studio": {"name": "Fotostudio Glockenbach", "address": "Reichenbachstraße 27, 80469 München, Germany", "lat": 48.1306, "lon": 11.5763},
        "landmark": {"name": "Marienplatz", "address": "Marienplatz 8, 80331 München, Germany", "lat": 48.1378, "lon": 11.5753},
        "museum": {"name": "Pinakothek der Moderne", "address": "Barer Straße 40, 80333 München, Germany", "lat": 48.1472, "lon": 11.5722},
        "cameraStore": {"name": "Foto Video Sauter", "address": "Sonnenstraße 21, 80331 München, Germany", "lat": 48.1360, "lon": 11.5654},
        "market": {"name": "Viktualienmarkt", "address": "Viktualienmarkt 3, 80331 München, Germany", "lat": 48.1349, "lon": 11.5758},
        "park": {"name": "Englischer Garten", "address": "Englischer Garten 3, 80538 München, Germany", "lat": 48.1526, "lon": 11.5934},
        "venue": {"name": "Allianz Arena", "address": "Franz-Beckenbauer-Platz 5, 80939 München, Germany", "lat": 48.2197, "lon": 11.6263},
        "mall": {"name": "Fünf Höfe", "address": "Theatinerstraße 15, 80333 München, Germany", "lat": 48.1406, "lon": 11.5750},
        "culture": {"name": "Haus der Kunst", "address": "Prinzregentenstraße 1, 80538 München, Germany", "lat": 48.1441, "lon": 11.5860},
        "dayTrip1": {"name": "Schloss Neuschwanstein", "address": "Neuschwansteinstraße 20, 87645 Schwangau, Germany", "lat": 47.5585, "lon": 10.7500},
        "dayTrip2": {"name": "Kloster Andechs", "address": "Bergstraße 2, 82346 Andechs, Germany", "lat": 47.9747, "lon": 11.1826},
        "gallery": {"name": "Museum Brandhorst", "address": "Theresienstraße 35a, 80333 München, Germany", "lat": 48.1481, "lon": 11.5741},
    },
}


def _build_role_locale(identifier: str) -> dict:
    strings = STRINGS[identifier]
    meta = LOCALE_META[identifier]
    research = RESEARCH[identifier]
    scale = meta["feeScale"]

    places = {role: (place["lat"], place["lon"]) for role, place in research.items()}
    # Studio uses a bare street address (no invented business name); every other
    # role is "Name, address" so the place reads recognizably on the card.
    labels = {
        role: place["address"] if role == "studio" else f"{place['name']}, {place['address']}"
        for role, place in research.items()
    }

    trips = []
    for role_trip in ROLE_TRIPS:
        entry = dict(
            o=role_trip["o"], d=role_trip["d"], cls=role_trip["cls"],
            purpose=strings[role_trip["purpose"]] if role_trip.get("purpose") else None,
            notes=strings[role_trip["note"]],
            tolls=0, parking=round(role_trip["parking"] * scale, 2),
            m=role_trip["m"], day=role_trip["day"], h=role_trip["h"], mn=role_trip["mn"],
        )
        if "sug" in role_trip:
            # (purpose_key, event_key) is a business suggestion; a third element
            # overrides the classification, and a personal one carries no
            # purpose — the row tints the line red and shows the event alone.
            purpose_key, event_key, *rest = role_trip["sug"]
            entry["suggestion"] = dict(
                classification=rest[0] if rest else "business",
                businessPurpose=strings[purpose_key] if purpose_key else None,
                calendarEventTitle=strings[event_key],
            )
        trips.append(entry)

    return {
        "mileageRate": {"amountPerUnit": meta["rate"], "unit": "kilometers"},
        "currencyCode": meta["currency"],
        "businessPurposePresets": [strings["photoShoot"], strings["clientMeeting"], strings["supplies"]],
        "places": places,
        "labels": labels,
        "trips": trips,
    }


for _locale in STRINGS:
    LOCALES[_locale] = _build_role_locale(_locale)


def fetch(places: dict, o: str, d: str) -> tuple[str, float, float]:
    lat0, lon0 = places[o]
    lat1, lon1 = places[d]
    url = OSRM.format(c0=f"{lon0},{lat0}", c1=f"{lon1},{lat1}")
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                data = json.load(resp)
            route = data["routes"][0]
            return route["geometry"], route["distance"], route["duration"]
        except Exception as error:  # noqa: BLE001 — retry demo-server hiccups
            last_error = error
            time.sleep(2.0 * (attempt + 1))
    raise RuntimeError(f"OSRM failed for {o} -> {d}: {last_error}")


def build_locale(identifier: str, catalog: dict) -> dict:
    trips = []
    # A photographer drives the same pairs repeatedly, so the skeleton reuses
    # them. Fetching once per pair keeps the run off the demo server's patience
    # and — more importantly — makes a repeated drive draw the identical route.
    routes: dict[tuple[str, str], tuple[str, float, float]] = {}
    for trip in catalog["trips"]:
        key = (trip["o"], trip["d"])
        if key not in routes:
            routes[key] = fetch(catalog["places"], *key)
            time.sleep(0.4)
        geometry, distance_m, duration_s = routes[key]
        minutes = max(4, round(duration_s / 60))
        entry = {
            "month": trip["m"],
            "day": trip["day"],
            "hour": trip["h"],
            "minute": trip["mn"],
            "durationMinutes": minutes,
            "distanceMeters": round(distance_m, 1),
            "origin": catalog["labels"][trip["o"]],
            "destination": catalog["labels"][trip["d"]],
            "classification": trip["cls"],
            "businessPurpose": trip["purpose"],
            "notes": trip["notes"],
            "tolls": trip["tolls"],
            "parking": trip["parking"],
            "encodedRoute": geometry,
        }
        if trip.get("suggestion"):
            entry["suggestion"] = trip["suggestion"]
        trips.append(entry)
        print(
            f"[{identifier}] {trip['o']} -> {trip['d']}: "
            f"{distance_m / 1609.344:.1f} mi, {minutes} min",
            file=sys.stderr,
        )
    return {
        "mileageRate": catalog["mileageRate"],
        # Must be emitted: the app pins reports to this currency, and a locale
        # slice without it falls back to USD in a French or Mexican capture.
        "currencyCode": catalog["currencyCode"],
        "businessPurposePresets": catalog["businessPurposePresets"],
        "trips": trips,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", action="append",
                        help="regenerate only these locales, merging into the existing JSON")
    args = parser.parse_args()

    wanted = args.locale or list(LOCALES)
    unknown = [loc for loc in wanted if loc not in LOCALES]
    if unknown:
        parser.error(f"unknown locale(s) {unknown}; known: {list(LOCALES)}")

    existing: dict = {}
    if OUTPUT.exists():
        existing = json.loads(OUTPUT.read_text())

    for identifier in wanted:
        existing[identifier] = build_locale(identifier, LOCALES[identifier])

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(existing, indent=2, ensure_ascii=False) + "\n")
    size_kb = OUTPUT.stat().st_size / 1024
    print(f"wrote {OUTPUT} ({size_kb:.0f} KB, locales: {sorted(existing)})",
          file=sys.stderr)


if __name__ == "__main__":
    main()

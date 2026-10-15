"""
Downloads the neighborhood and council district boundaries from the City of
Baltimore's public ArcGIS layers (the same layers as the population tables)
and saves them as GeoJSON in outputs/, so Tableau can draw filled maps.

The shapes are simplified to about 5 meters (maxAllowableOffset), which keeps
the files small with no visible change at city scale. Each shape gets one
property named like the matching CSV column (neighborhood, council_district),
so Tableau can join the shapes to the CSVs directly.

Usage (from the project folder): python3 scripts/download_boundaries.py
"""

import json
import urllib.request

BASE = "https://services1.arcgis.com/UWYHeuuJISiGmgXx/ArcGIS/rest/services"

LAYERS = [
    {
        "layer": "Neighborhood_Statistical_Area_(NSA)_Boundaries_(1)",
        "field": "Name",
        "key": "neighborhood",
        "convert": str,
        "out": "outputs/neighborhoods.geojson",
    },
    {
        "layer": "Baltimore_City_Council_Districts_UPDATED_04302026_USE_THIS_LAYER",
        "field": "AREA_NAME",
        "key": "council_district",
        "convert": int,
        "out": "outputs/council_districts.geojson",
    },
]

for spec in LAYERS:
    url = (
        f"{BASE}/{spec['layer']}/FeatureServer/0/query?where=1%3D1"
        f"&outFields={spec['field']}&outSR=4326&f=geojson"
        f"&geometryPrecision=6&maxAllowableOffset=0.00005"
    )
    with urllib.request.urlopen(url) as response:
        data = json.load(response)
    for feature in data["features"]:
        value = feature["properties"][spec["field"]]
        feature["properties"] = {spec["key"]: spec["convert"](value)}
    # Sorted, so downloading again gives the same file.
    data["features"].sort(key=lambda f: f["properties"][spec["key"]])
    with open(spec["out"], "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(f"{spec['out']}: {len(data['features'])} shapes")

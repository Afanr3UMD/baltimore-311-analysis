"""
Downloads the two 2020 Census population tables from the City of Baltimore's
public ArcGIS layers and saves them as CSVs in data/raw/.

Usage (from the project folder): python3 scripts/download_population.py
"""

import csv
import json
import urllib.request

BASE = "https://services1.arcgis.com/UWYHeuuJISiGmgXx/ArcGIS/rest/services"

LAYERS = [
    {
        "layer": "Neighborhood_Statistical_Area_(NSA)_Boundaries_(1)",
        "fields": ["Name", "Population"],
        "order_by": "Name",
        "header": ["neighborhood", "population_2020"],
        "out": "data/raw/population_neighborhoods_2020.csv",
    },
    {
        "layer": "Baltimore_City_Council_Districts_UPDATED_04302026_USE_THIS_LAYER",
        "fields": ["AREA_NAME", "totalPop"],
        "order_by": "OBJECTID",
        "header": ["council_district", "population_2020"],
        "out": "data/raw/population_council_districts_2020.csv",
    },
]

for spec in LAYERS:
    url = (
        f"{BASE}/{spec['layer']}/FeatureServer/0/query?where=1%3D1"
        f"&outFields={','.join(spec['fields'])}&returnGeometry=false"
        f"&orderByFields={spec['order_by']}&f=json"
    )
    with urllib.request.urlopen(url) as response:
        features = json.load(response)["features"]
    with open(spec["out"], "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(spec["header"])
        for feature in features:
            writer.writerow([feature["attributes"][k] for k in spec["fields"]])
    print(f"{spec['out']}: {len(features)} rows")

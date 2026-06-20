"""
Train YOLO26n on the merged Snug furniture dataset.

Run from the repo root:
    python ml/scripts/train.py

Requires merge_datasets.py to have been run first.
Output: ~/snug-training/runs/snug_furniture_v1/weights/best.pt
"""

from pathlib import Path
from ultralytics import YOLO

MERGED_DATA_YAML = Path.home() / "snug-training" / "datasets" / "merged" / "data.yaml"
RUNS_DIR         = Path.home() / "snug-training" / "runs"

model = YOLO("yolo26n.pt")

results = model.train(
    data=str(MERGED_DATA_YAML),
    epochs=100,
    imgsz=640,
    batch=16,           # reduce to 8 if MPS hits memory pressure
    device="mps",
    workers=0,      # MPS forces this to 0 regardless — explicit is cleaner
    cache=True,     # cache images in RAM after epoch 1, eliminates I/O bottleneck
    project=str(RUNS_DIR),
    name="snug_furniture_v1",
    # Augmentation
    mosaic=1.0,
    mixup=0.1,
    degrees=5.0,        # rooms are rarely tilted
    flipud=0.0,         # rooms don't flip upside down
    fliplr=0.5,
    hsv_h=0.015,
    hsv_s=0.7,
    hsv_v=0.4,
    # Regularization
    dropout=0.1,
    weight_decay=0.0005,
    # Stop early if val mAP50 doesn't improve for 20 epochs
    patience=20,
    save_period=10,
)

print("Best mAP50:", results.results_dict.get("metrics/mAP50(B)", "n/a"))
print("Weights saved to:", RUNS_DIR / "snug_furniture_v1" / "weights" / "best.pt")

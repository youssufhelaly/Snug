"""
Fine-tune v2 best checkpoint with nightstand_robocup only (no desk_usthb).

Run from the repo root:
    python ml/scripts/finetune_v4.py

Starts from v2 best.pt (ep 32, mAP50=0.725).
Nightstand fix only — preserves v2's strong desk performance.
Output: ~/snug-training/runs/snug_furniture_v4/weights/best.pt
"""

from pathlib import Path
from ultralytics import YOLO

BEST_CHECKPOINT  = Path.home() / "snug-training/runs/snug_furniture_v2/weights/best.pt"
MERGED_DATA_YAML = Path.home() / "snug-training/datasets/merged/data.yaml"
RUNS_DIR         = Path.home() / "snug-training/runs"

model = YOLO(str(BEST_CHECKPOINT))

results = model.train(
    data=str(MERGED_DATA_YAML),
    epochs=10,
    imgsz=640,
    batch=16,
    device="mps",
    workers=0,
    cache=False,
    optimizer="SGD",
    lr0=0.0005,
    lrf=0.01,
    project=str(RUNS_DIR),
    name="snug_furniture_v4",
    mosaic=1.0,
    mixup=0.1,
    degrees=5.0,
    flipud=0.0,
    fliplr=0.5,
    hsv_h=0.015,
    hsv_s=0.7,
    hsv_v=0.4,
    dropout=0.1,
    weight_decay=0.0005,
    patience=5,
    save_period=2,
)

print("Best mAP50:", results.results_dict.get("metrics/mAP50(B)", "n/a"))
print("Weights saved to:", RUNS_DIR / "snug_furniture_v4" / "weights" / "best.pt")

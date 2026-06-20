"""
Fine-tune v2 best checkpoint with the expanded dataset (+ nightstand_robocup).

Run from the repo root:
    python ml/scripts/finetune_v3.py

Starts from v2 best.pt (ep 32, mAP50=0.725) and fine-tunes with the
nightstand_robocup dataset added to the merge.
Output: ~/snug-training/runs/snug_furniture_v3/weights/best.pt
"""

from pathlib import Path
from ultralytics import YOLO

BEST_CHECKPOINT  = Path.home() / "snug-training/runs/snug_furniture_v2/weights/best.pt"
MERGED_DATA_YAML = Path.home() / "snug-training/datasets/merged/data.yaml"
RUNS_DIR         = Path.home() / "snug-training/runs"

model = YOLO(str(BEST_CHECKPOINT))

results = model.train(
    data=str(MERGED_DATA_YAML),
    epochs=30,
    imgsz=640,
    batch=16,
    device="mps",
    workers=0,
    cache=False,
    optimizer="SGD",
    lr0=0.0005,       # half of v2 lr — we're close to convergence
    lrf=0.01,
    project=str(RUNS_DIR),
    name="snug_furniture_v3",
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
    patience=7,
    save_period=2,
)

print("Best mAP50:", results.results_dict.get("metrics/mAP50(B)", "n/a"))
print("Weights saved to:", RUNS_DIR / "snug_furniture_v3" / "weights" / "best.pt")

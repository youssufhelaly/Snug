"""
Fine-tune the best checkpoint on the expanded merged dataset.

Run from the repo root:
    python ml/scripts/finetune.py

Starts from best.pt (epoch 53, mAP50=0.643) and continues training
with the full dataset including furniture_lpvqi and furny additions.
Output: ~/snug-training/runs/snug_furniture_v2/weights/best.pt
"""

from pathlib import Path
from ultralytics import YOLO

BEST_CHECKPOINT  = Path.home() / "snug-training/runs/snug_furniture_v1/weights/best.pt"
MERGED_DATA_YAML = Path.home() / "snug-training/datasets/merged/data.yaml"
RUNS_DIR         = Path.home() / "snug-training/runs"

model = YOLO(str(BEST_CHECKPOINT))

results = model.train(
    data=str(MERGED_DATA_YAML),
    epochs=50,
    imgsz=640,
    batch=16,
    device="mps",
    workers=0,
    cache=False,      # 29k images need ~47GB to cache — not feasible on 24GB M4
    optimizer="SGD",  # explicit — prevents auto from overriding lr0
    lr0=0.001,        # 10× lower than default, preserves v1 knowledge
    lrf=0.01,
    project=str(RUNS_DIR),
    name="snug_furniture_v2",
    # Keep augmentation identical to v1
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
    patience=15,
    save_period=10,
)

print("Best mAP50:", results.results_dict.get("metrics/mAP50(B)", "n/a"))
print("Weights saved to:", RUNS_DIR / "snug_furniture_v2" / "weights" / "best.pt")

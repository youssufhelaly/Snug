"""
Per-class evaluation of the best v2 checkpoint.

Run from the repo root:
    python ml/scripts/eval.py

Prints per-class AP50 and a summary table.
"""

from pathlib import Path
from ultralytics import YOLO

BEST_CHECKPOINT  = Path.home() / "snug-training/runs/snug_furniture_v4/weights/best.pt"
MERGED_DATA_YAML = Path.home() / "snug-training/datasets/merged/data.yaml"

# v4 (bundled) is the 11-class model. A v5 that folded nightstand into side_table
# (nc=10) was trained and REJECTED — the forced head reinit regressed every class
# (mAP50 0.743→0.705). See the YOLO memory note. 11 classes:
MASTER_CLASSES = [
    "sofa", "chair", "bed", "desk", "dining_table",
    "coffee_table", "side_table", "bookshelf", "dresser", "wardrobe", "nightstand",
]

model = YOLO(str(BEST_CHECKPOINT))

metrics = model.val(
    data=str(MERGED_DATA_YAML),
    imgsz=640,
    device="mps",
    workers=0,
    split="val",
    verbose=True,
)

print("\n── Per-class AP50 ──────────────────────────────────")
ap50_per_class = metrics.box.ap50
for cls_name, ap in zip(MASTER_CLASSES, ap50_per_class):
    bar = "█" * int(ap * 30)
    flag = " ⚠️ " if ap < 0.4 else ""
    print(f"  {cls_name:<15} {ap:.3f}  {bar}{flag}")

print(f"\n  {'mAP50':<15} {metrics.box.map50:.3f}")
print(f"  {'mAP50-95':<15} {metrics.box.map:.3f}")

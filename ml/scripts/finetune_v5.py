"""
⚠️ REJECTED EXPERIMENT — kept for the record, NOT used. v5 trained fine but the
nc 11→10 change FORCED a detection-head reinitialization, which regressed EVERY
class vs v4 (mAP50 0.743→0.705; bookshelf 0.772→0.614, desk 0.689→0.605, etc.).
The lone gain — side_table recall 0.382→0.532 (absorbing nightstand) — wasn't
worth the broad regression, so v4 stays bundled. If retrying the merge, keep
nc=11 with nightstand as a 0-instance class to PRESERVE the head. See YOLO memory.

Fine-tune the best checkpoint on the 10-class taxonomy (nightstand folded
into side_table).

Run from the repo root:
    python ml/scripts/finetune_v5.py

Starts from v4 best.pt (most-trained backbone). The data.yaml now has nc=10
(no nightstand) — Ultralytics detects the nc change and reinitializes the
detection head while transferring the backbone, so this converges fast.

Why v5 exists: nightstand was the worst class (AP50 0.554, recall 0.382) because
it confused with side_table. Collapsing the pair removes that ceiling; this run
should lift side_table and overall recall. Re-run merge_datasets.py FIRST so the
merged dataset is regenerated at 10 classes.

Output: ~/snug-training/runs/snug_furniture_v5/weights/best.pt
"""

from pathlib import Path
from ultralytics import YOLO

BEST_CHECKPOINT  = Path.home() / "snug-training/runs/snug_furniture_v4/weights/best.pt"
MERGED_DATA_YAML = Path.home() / "snug-training/datasets/merged/data.yaml"
RUNS_DIR         = Path.home() / "snug-training/runs"

model = YOLO(str(BEST_CHECKPOINT))

results = model.train(
    data=str(MERGED_DATA_YAML),
    epochs=20,
    imgsz=640,
    batch=16,
    device="mps",
    workers=0,
    cache=False,
    optimizer="SGD",
    lr0=0.0008,         # slightly higher than v4: the head is reinitialized
    lrf=0.01,
    project=str(RUNS_DIR),
    name="snug_furniture_v5",
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
    patience=8,
    save_period=2,
)

print("Best mAP50:", results.results_dict.get("metrics/mAP50(B)", "n/a"))
print("Weights saved to:", RUNS_DIR / "snug_furniture_v5" / "weights" / "best.pt")

"""
Export best checkpoint to CoreML for iOS deployment.

Run from the repo root:
    python ml/scripts/export_coreml.py

Exports to ~/snug-training/runs/snug_furniture_v2/weights/best.mlpackage
Then copy that file into the Xcode project as YOLO26nFurniture.mlpackage
"""

from pathlib import Path
from ultralytics import YOLO

BEST_CHECKPOINT = Path.home() / "snug-training/runs/snug_furniture_v2/weights/best.pt"

model = YOLO(str(BEST_CHECKPOINT))

model.export(
    format="coreml",
    imgsz=640,
    nms=False,   # raw tensor output — matches FurnitureDetectionService decoder
    half=False,  # float32 — more compatible across iOS devices
)

export_path = BEST_CHECKPOINT.with_suffix(".mlpackage")
print(f"\nExported: {export_path}")
print("\nNext: drag best.mlpackage into Xcode and rename it YOLO26nFurniture.mlpackage")

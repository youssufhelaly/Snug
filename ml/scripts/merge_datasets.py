"""
Merge multiple furniture detection datasets into a single YOLO-format dataset.

Run from the repo root:
    python ml/scripts/merge_datasets.py

Expects downloaded datasets at ~/snug-training/datasets/raw/
Writes merged dataset to   ~/snug-training/datasets/merged/
"""

import os
import shutil
import yaml
import random
from pathlib import Path
from tqdm import tqdm

# ── Paths ──────────────────────────────────────────────────────────────────────
TRAINING_ROOT = Path.home() / "snug-training"
RAW_ROOT      = TRAINING_ROOT / "datasets" / "raw"
MERGED_ROOT   = TRAINING_ROOT / "datasets" / "merged"

SPLIT_RATIO = 0.9  # 90% train, 10% val
SEED = 42

# ── Master class list ──────────────────────────────────────────────────────────
# These 11 classes are what the Snug app recognises (= the bundled v4 model's names).
# Index order matters — Swift reads labels by NAME from the model's `names` metadata.
#
# REJECTED EXPERIMENT (2026-06-22): folding `nightstand` into `side_table` (nc=10) to
# fix nightstand's low recall (0.382). It trained (v5) but the forced head reinit
# (nc 11→10) REGRESSED every class — mAP50 0.743→0.705 — so v5 was NOT shipped; v4
# (this 11-class taxonomy) stays bundled. If retried, keep nc=11 with nightstand as a
# 0-instance class so the head is preserved. See the YOLO memory note.
MASTER_CLASSES = {
    0:  "sofa",
    1:  "chair",
    2:  "bed",
    3:  "desk",
    4:  "dining_table",
    5:  "coffee_table",
    6:  "side_table",
    7:  "bookshelf",
    8:  "dresser",
    9:  "wardrobe",
    10: "nightstand",
}
CLASS_NAME_TO_ID = {v: k for k, v in MASTER_CLASSES.items()}

# ── Dataset configs ────────────────────────────────────────────────────────────
# class_map: source class name (exact string from data.yaml) → master class name
# Omitted source classes are silently dropped.

FURNITURE_FOCUSED_MAP = {
    # Sofas
    "Standard-Sofa":              "sofa",
    "2-Piece-Sectional-Sofa":     "sofa",
    "4-Piece-Sectional-Sofa":     "sofa",
    # Chairs (all seated single-person furniture)
    "Standard-Chair":             "chair",
    "Armchair":                   "chair",
    "Big-Armchair":               "chair",
    "Small-Armchair":             "chair",
    "Office-Chair":               "chair",
    "BeanBag-Chair":              "chair",
    "Egg-Chair":                  "chair",
    "Ottoman-Chair":              "chair",
    "Papasan-Chair":              "chair",
    "Stool":                      "chair",
    "Bench-Chair":                "chair",
    # Beds
    "Big-Bed":                    "bed",
    "Twin-Bed":                   "bed",
    "Child-Bed":                  "bed",
    "Bunk-Bed":                   "bed",
    # Desks
    "Desk":                       "desk",
    "Dressing-Table":             "desk",
    # Dining / large tables
    "Standard-Table":             "dining_table",
    "Big-Standard-Table":         "dining_table",
    "Small-Standard-Table":       "dining_table",
    "Game-Table":                 "dining_table",
    # Coffee / low tables
    "Low-Table":                  "coffee_table",
    "Big-Low-Table":              "coffee_table",
    "Small-Low-Table":            "coffee_table",
    "Gueridon":                   "coffee_table",
    # Side tables / TV stands
    "TV-Stand":                   "side_table",
    # Bookshelves / storage shelves
    "Shelve-Storage":             "bookshelf",
    "Big-Shelve-Storage":         "bookshelf",
    "Small-Shelve-Storage":       "bookshelf",
    "Small-Hutch":                "bookshelf",
    # Dressers / credenzas / display cabinets
    "Sideboard-Credenza-Storage": "dresser",
    "Big-Sideboard-Credenza-Storage": "dresser",
    "Small-Sideboard-Credenza-Storage": "dresser",
    "FileDrawer-Storage":         "dresser",
    "Display-Cabinet":            "dresser",
    "Big-Display-Cabinet":        "dresser",
    "Small-Display-Cabinet":      "dresser",
    "Bahut":                      "dresser",
    # Wardrobes
    "Wardrobe":                   "wardrobe",
    "Big-Wardrobe":               "wardrobe",
    # Nightstands
    "Bedside-Table":              "nightstand",
}

HOMEOBJECTS_MAP = {
    # HomeObjects-3K generic classes (indices 0-11)
    "bed":      "bed",
    "sofa":     "sofa",
    "chair":    "chair",
    "table":    "dining_table",
    "wardrobe": "wardrobe",
    # lamp, tv, laptop, window, door, potted plant, photo frame → dropped
}

AXELITES_MAP = {
    # Has duplicate classes with mixed case — map both spellings
    "Bed":                "bed",
    "bed":                "bed",
    "master bed":         "bed",
    "Cabinet":            "dresser",
    "cabinet":            "dresser",
    "cupboard":           "dresser",
    "sideboard":          "dresser",
    "Chair":              "chair",
    "chair":              "chair",
    "arm chair":          "chair",
    "Swivel_C":           "chair",
    "stool":              "chair",
    "Couch":              "sofa",
    "Sofa":               "sofa",
    "sofa":               "sofa",
    "Shelf":              "bookshelf",
    "TV stand":           "side_table",
    "Table":              "dining_table",
    "table":              "dining_table",
    "dining table":       "dining_table",
    "dinning-table":      "dining_table",
    "Closet":             "wardrobe",
    "closet":             "wardrobe",
    "transparent closet": "wardrobe",
    "wardrobe":           "wardrobe",
    "nightstand":         "nightstand",
    "drawer near bed":    "nightstand",
    # Carpet, floor types, walls, appliances, lamps, frames → dropped
}

# indoor_furniture_zqazh is unusable — its data.yaml contains Roboflow
# marketing copy instead of class names. Skipped.

FURNITURE_LPVQI_MAP = {
    # 111-0ta46/furniture-lpvqi — 18k images, strong coffee_table coverage
    "sofa":         "sofa",
    "chair":        "chair",
    "bed":          "bed",
    "coffee table": "coffee_table",
    "dining table": "dining_table",
    "Side table":   "side_table",
    "Nightstand":   "nightstand",
    "wardrobe":     "wardrobe",
    "TV cabinet":   "side_table",
    # Refrigerator, air conditioner, laptop, tv, Kitchen cabinets, Lockers → dropped
}

FURNY_MAP = {
    # mover/furny — 11k images, color-variant coffee table labels
    "Sofa":              "sofa",
    "sofa":              "sofa",
    "sofa_black":        "sofa",
    "sofa_grey":         "sofa",
    "sofa_green":        "sofa",
    "sofa_brown":        "sofa",
    "sofa_beige":        "sofa",
    "sofa_white":        "sofa",
    "couch":             "sofa",
    "Chair":             "chair",
    "chair":             "chair",
    "chair_beige":       "chair",
    "chair_black":       "chair",
    "chair_white":       "chair",
    "chair_grey":        "chair",
    "chair_brown":       "chair",
    "Swivel_C":          "chair",
    "Bed":               "bed",
    "bed":               "bed",
    "unmade":            "bed",
    "desk":              "desk",
    "Table":             "dining_table",
    "table":             "dining_table",
    "table_white":       "dining_table",
    "table_brown":       "dining_table",
    "table_black":       "dining_table",
    "dinning-table":     "dining_table",
    "coffee table":      "coffee_table",
    "coffeetable_brown": "coffee_table",
    "coffeetable_black": "coffee_table",
    "coffeetable_grey":  "coffee_table",
    "coffeetable_beige": "coffee_table",
    "coffeetable_white": "coffee_table",
    "end table":         "side_table",
    "end table ":        "side_table",
    "tv_stand":          "side_table",
    "TV stand":          "side_table",
    "Shelf":             "bookshelf",
    "Shelving unit":     "bookshelf",
    "dresser":           "dresser",
    "Dresser":           "dresser",
    "dresser_brown":     "dresser",
    "tvdrawer_grey":     "dresser",
    "tvdrawer_white":    "dresser",
    "tvdrawer_green":    "dresser",
    "tvdrawer_brown":    "dresser",
    "tvdrawer_beige":    "dresser",
    "wardrobe":          "wardrobe",
    "Closet":            "wardrobe",
    "nightstand":        "nightstand",
    "Bedside table":     "nightstand",
    "bedside table":     "nightstand",
    # Lamps, TV, curtains, plants, pictures, monitors → dropped
}

NIGHTSTAND_ROBOCUP_MAP = {
    "nightstand": "nightstand",
}

DESK_USTHB_MAP = {
    "desk":  "desk",
    "chair": "chair",
    # keyboard, laptop, mouse, person, tv → dropped
}

DATASET_CONFIGS = [
    {
        "name":      "furniture_focused",
        "yaml":      Path("/Users/helaly/repos/datasets/raw/furniture_focused/data.yaml"),
        "splits":    ["train", "valid"],
        "class_map": FURNITURE_FOCUSED_MAP,
    },
    {
        "name":      "homeobjects",
        "yaml":      Path("/Users/helaly/repos/datasets/raw/homeobjects/homeobjects-3k/HomeObjects-3K.yaml"),
        "splits":    ["train", "val"],
        "class_map": HOMEOBJECTS_MAP,
    },
    {
        "name":      "axelites",
        "yaml":      Path("/Users/helaly/repos/datasets/raw/axelites/data.yaml"),
        "splits":    ["train", "valid"],
        "class_map": AXELITES_MAP,
    },
    {
        "name":      "furniture_lpvqi",
        "yaml":      Path("/Users/helaly/repos/datasets/raw/furniture_lpvqi/data.yaml"),
        "splits":    ["train", "valid"],
        "class_map": FURNITURE_LPVQI_MAP,
    },
    {
        "name":      "furny",
        "yaml":      Path("/Users/helaly/repos/datasets/raw/furny/data.yaml"),
        "splits":    ["train", "valid"],
        "class_map": FURNY_MAP,
    },
    {
        "name":      "nightstand_robocup",
        "yaml":      Path("/Users/helaly/repos/datasets/raw/nightstand.yolov8/data.yaml"),
        "splits":    ["train", "valid"],
        "class_map": NIGHTSTAND_ROBOCUP_MAP,
    },
    # NOTE: desk_usthb is intentionally NOT wired in. It was tried in v3 (the
    # "expanded dataset") and measurably REGRESSED the model — notably tanked
    # nightstand — so v4 dropped it. (Likely domain shift: it's office scenes with
    # monitors/laptops/people, a narrow distribution far from real rooms, and only
    # desk+chair are labeled.) DESK_USTHB_MAP is kept above for reference only.
    # Don't re-add it without re-measuring. Fix desk→dining_table some other way.
]

# ── Helpers ────────────────────────────────────────────────────────────────────

def build_index_remap(yaml_path: Path, class_map: dict) -> dict:
    """Return {src_class_index: master_class_index} from a dataset's data.yaml."""
    with open(yaml_path) as f:
        d = yaml.safe_load(f)
    names = d["names"]
    if isinstance(names, dict):
        names = [names[i] for i in sorted(names)]

    remap = {}
    for i, name in enumerate(names):
        master_name = class_map.get(name)
        if master_name and master_name in CLASS_NAME_TO_ID:
            remap[i] = CLASS_NAME_TO_ID[master_name]
    return remap


def remap_label_file(src: Path, dst: Path, remap: dict) -> bool:
    """Re-index a YOLO .txt label file. Returns True if any annotations survived."""
    if not src.exists():
        return False
    lines_out = []
    for line in src.read_text().splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        src_cls = int(parts[0])
        if src_cls not in remap:
            continue
        lines_out.append(f"{remap[src_cls]} " + " ".join(parts[1:]))
    if not lines_out:
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(lines_out))
    return True


def find_split_dirs(yaml_dir: Path, split: str):
    """Handle images/train, train/images, and yaml path: prefix layouts."""
    candidates = [
        (yaml_dir / "images" / split, yaml_dir / "labels" / split),
        (yaml_dir / split / "images", yaml_dir / split / "labels"),
    ]
    for img, lbl in candidates:
        if img.exists():
            return img, lbl
    return None, None


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    random.seed(SEED)

    all_pairs = []  # (img_path, lbl_path, remap_dict)

    for cfg in DATASET_CONFIGS:
        yaml_path = cfg["yaml"]
        if not yaml_path.exists():
            print(f"SKIP (not downloaded): {cfg['name']}")
            continue

        remap = build_index_remap(yaml_path, cfg["class_map"])
        yaml_dir = yaml_path.parent
        kept = sum(1 for v in remap.values() if v is not None)
        print(f"\n{cfg['name']}: {kept} source classes mapped")

        for split in cfg["splits"]:
            img_dir, lbl_dir = find_split_dirs(yaml_dir, split)
            if img_dir is None:
                print(f"  WARNING: split '{split}' not found in {yaml_dir}")
                continue

            images = list(img_dir.glob("*.[jp][pn]g")) + list(img_dir.glob("*.jpeg"))
            for img_path in tqdm(images, desc=f"  {split}"):
                lbl_path = lbl_dir / img_path.with_suffix(".txt").name
                all_pairs.append((img_path, lbl_path, remap))

    if not all_pairs:
        print("\nNo datasets found. Run download_datasets.py first.")
        return

    random.shuffle(all_pairs)
    split_idx   = int(len(all_pairs) * SPLIT_RATIO)
    train_pairs = all_pairs[:split_idx]
    val_pairs   = all_pairs[split_idx:]
    print(f"\nTotal: {len(all_pairs)} images → {len(train_pairs)} train / {len(val_pairs)} val")

    # Create output dirs
    for split in ["train", "val"]:
        (MERGED_ROOT / "images" / split).mkdir(parents=True, exist_ok=True)
        (MERGED_ROOT / "labels" / split).mkdir(parents=True, exist_ok=True)

    skipped = 0
    for img_path, lbl_path, remap in tqdm(train_pairs, desc="Copying train"):
        dst_img = MERGED_ROOT / "images" / "train" / img_path.name
        dst_lbl = MERGED_ROOT / "labels" / "train" / lbl_path.with_suffix(".txt").name
        if remap_label_file(lbl_path, dst_lbl, remap):
            shutil.copy2(img_path, dst_img)
        else:
            skipped += 1

    for img_path, lbl_path, remap in tqdm(val_pairs, desc="Copying val"):
        dst_img = MERGED_ROOT / "images" / "val" / img_path.name
        dst_lbl = MERGED_ROOT / "labels" / "val" / lbl_path.with_suffix(".txt").name
        if remap_label_file(lbl_path, dst_lbl, remap):
            shutil.copy2(img_path, dst_img)
        else:
            skipped += 1

    print(f"\nSkipped {skipped} images with no kept annotations.")

    # Write data.yaml
    data_yaml = {
        "path": str(MERGED_ROOT),
        "train": "images/train",
        "val":   "images/val",
        "nc":    len(MASTER_CLASSES),
        "names": MASTER_CLASSES,
    }
    out_yaml = MERGED_ROOT / "data.yaml"
    with open(out_yaml, "w") as f:
        yaml.dump(data_yaml, f, default_flow_style=False)

    print(f"Wrote {out_yaml}")
    print("\nDone. Run verify_distribution.py next.")


if __name__ == "__main__":
    main()

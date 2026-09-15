"""Offline package integrity and protobuf contract check; does not execute Core ML."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "BerkeleyPlate/Resources/Models"


def verify():
    manifest = json.loads((ROOT / "Tools/model-lock.json").read_text())
    actual_paths = {p.relative_to(MODEL_DIR).as_posix() for p in MODEL_DIR.rglob("*") if p.is_file()}
    assert actual_paths == set(manifest["files"]), "Missing or unexpected model files"
    for name, expected in manifest["files"].items():
        raw = (MODEL_DIR / name).read_bytes()
        assert len(raw) == expected["bytes"], name
        assert hashlib.sha256(raw).hexdigest() == expected["sha256"], name

    from coremltools.proto import Model_pb2
    for name, contract in manifest["contracts"].items():
        spec = Model_pb2.Model()
        spec.ParseFromString((MODEL_DIR / name / "Data/com.apple.CoreML/model.mlmodel").read_bytes())
        assert spec.WhichOneof("Type") == "mlProgram", name
        for direction in ("input", "output"):
            features = {v.name: v.type.multiArrayType for v in getattr(spec.description, direction)}
            assert set(features) == set(contract[direction]), (name, direction)
            for key, shape in contract[direction].items():
                assert list(features[key].shape) == shape, key
                assert features[key].dataType == 65568, key  # FLOAT32 interface, FP16 internal
        if "decoder" in name:
            sparse = next(v for v in spec.description.input if v.name == "sparse_embeddings")
            shapes = [list(v.shape) for v in sparse.type.multiArrayType.enumeratedShapes.shapes]
            assert all([1, n, 256] in shapes for n in range(2, 11))
    print(f"PASS: {len(actual_paths)} pinned files, encoder/decoder shapes and prompt token range")


if __name__ == "__main__":
    verify()

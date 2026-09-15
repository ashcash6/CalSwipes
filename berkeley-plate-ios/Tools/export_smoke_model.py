"""Export an UNTRAINED grayscale fixture for testing CoreML image/tensor plumbing.

This does not segment food, classify a menu or estimate depth, mass or nutrition.
Run on a Mac with Python 3.11 and requirements-models.txt installed.
"""
import argparse
import json
from pathlib import Path
import numpy as np
import torch
import coremltools as ct


class SmokeModel(torch.nn.Module):
    def forward(self, image):
        return image.mean(dim=1, keepdim=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("Tests/Models/PlateSmoke.mlpackage"))
    args = parser.parse_args()
    if args.output.suffix != ".mlpackage":
        parser.error("output must end with .mlpackage")
    model = SmokeModel().eval()
    inputs = torch.zeros(1, 3, 256, 256)
    traced = torch.jit.trace(model, inputs)
    converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        inputs=[ct.ImageType(name="image", shape=inputs.shape, color_layout=ct.colorlayout.RGB, scale=1/255.0)],
        outputs=[ct.TensorType(name="luma", dtype=np.float32)], compute_precision=ct.precision.FLOAT16)
    converted.short_description = "UNTRAINED integration fixture. RGB average only. Not food analysis."
    converted.user_defined_metadata["purpose"] = "integration_smoke_only"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output))
    print(json.dumps({"output":str(args.output), "torch":torch.__version__, "coremltools":ct.__version__,
                      "input":"RGB 256x256", "output_tensor":"luma [1,1,256,256]", "trained":False}, indent=2))


if __name__ == "__main__":
    main()

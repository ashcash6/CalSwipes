"""Rebuild compatible packages from the pinned official trained MobileSAM checkpoint.

Run on macOS with Tools/requirements-mobilesam.txt. Not a bit-for-bit reproduction
of the third-party preconverted packages: this is our independently pinned recipe.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import torch

CHECKPOINT_SHA256 = "6dbb90523a35330fedd7f1d3dfc66f995213d81b29a5ca8108dbcdd4e37d6c2f"


class Decoder(torch.nn.Module):
    def __init__(self, sam):
        super().__init__()
        self.decoder = sam.mask_decoder
        self.register_buffer("pe", sam.prompt_encoder.get_dense_pe())

    def forward(self, image_embeddings, sparse_embeddings, dense_embeddings):
        return self.decoder(image_embeddings=image_embeddings, image_pe=self.pe,
                            sparse_prompt_embeddings=sparse_embeddings,
                            dense_prompt_embeddings=dense_embeddings, multimask_output=True)


def prompt_weights(sam):
    p = sam.prompt_encoder
    return dict(embed_dim=p.embed_dim, image_embedding_size=list(p.image_embedding_size),
                input_image_size=list(p.input_image_size),
                gaussian_matrix=p.pe_layer.positional_encoding_gaussian_matrix.detach().tolist(),
                point_embeddings=[e.weight.detach()[0].tolist() for e in p.point_embeddings],
                not_a_point_embed=p.not_a_point_embed.weight.detach()[0].tolist(),
                no_mask_embed=p.no_mask_embed.weight.detach()[0].tolist())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference-only", action="store_true", help="CPU check and fixtures; no conversion")
    parser.add_argument("--trace-only", action="store_true", help="Verify PyTorch export traces; no Core ML conversion")
    args = parser.parse_args()
    if hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() != CHECKPOINT_SHA256:
        raise ValueError("Checkpoint hash mismatch")
    sys.path.insert(0, str(args.source.resolve()))
    from mobile_sam import sam_model_registry
    torch.manual_seed(7)
    torch.set_num_threads(4)
    sam = sam_model_registry["vit_t"](checkpoint=str(args.checkpoint)).eval()
    args.output.mkdir(parents=True, exist_ok=True)
    weights = prompt_weights(sam)
    (args.output / "mobile_sam_prompt_encoder_weights.json").write_text(json.dumps(weights))
    # Asymmetric portrait coordinates test scale, x/y order, +0.5 and negative token.
    coords = torch.tensor([[[153.6, 204.8], [460.8, 819.2]]])  # normalized (.3,.2),(.9,.8), resized 512x1024
    labels = torch.tensor([[1, 0]])
    with torch.no_grad():
        sparse, dense = sam.prompt_encoder(points=(coords, labels), boxes=None, masks=None)
    (args.output / "prompt-reference.json").write_text(json.dumps({"sparse": sparse.flatten().tolist()}))
    if args.reference_only:
        bundled = Path(__file__).resolve().parents[1] / "BerkeleyPlate/Resources/Models/mobile_sam_prompt_encoder_weights.json"
        assert json.loads(bundled.read_text()) == weights, "Bundled prompt weights differ from upstream checkpoint"
        print("PASS: bundled prompt weights equal official trained checkpoint; PyTorch prompt fixture exported")
        return

    image = torch.zeros(1, 3, 1024, 1024)
    decoder = Decoder(sam).eval()
    with torch.no_grad():
        embedding = sam.image_encoder(image)
        expected_masks, expected_scores = decoder(embedding, sparse, dense)
        encoder_trace = torch.jit.trace(sam.image_encoder, image)
        decoder_trace = torch.jit.trace(decoder, (embedding, sparse, dense))
        torch.testing.assert_close(encoder_trace(image), embedding)
        for point_count in (1, 2, 9):
            test_coords = torch.full((1, point_count, 2), 128.0)
            test_labels = torch.ones((1, point_count), dtype=torch.int64)
            test_sparse, test_dense = sam.prompt_encoder(points=(test_coords, test_labels), boxes=None, masks=None)
            expected = decoder(embedding, test_sparse, test_dense)
            actual = decoder_trace(embedding, test_sparse, test_dense)
            for left, right in zip(actual, expected):
                torch.testing.assert_close(left, right)
                assert torch.isfinite(left).all()
    if args.trace_only:
        print("PASS: trained encoder and decoder traces match PyTorch for 1, 2 and 9 prompt points")
        return
    import coremltools as ct
    encoder_model = ct.convert(encoder_trace, convert_to="mlprogram",
        inputs=[ct.TensorType(name="image", shape=image.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="image_embeddings", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
    decoder_model = ct.convert(decoder_trace, convert_to="mlprogram",
        inputs=[ct.TensorType(name="image_embeddings", shape=embedding.shape, dtype=np.float32),
                ct.TensorType(name="sparse_embeddings", shape=ct.EnumeratedShapes([[1,n,256] for n in range(1,11)]), dtype=np.float32),
                ct.TensorType(name="dense_embeddings", shape=dense.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="masks", dtype=np.float32), ct.TensorType(name="iou_predictions", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
    encoder_model.save(str(args.output / "mobile_sam_encoder.mlpackage"))
    decoder_model.save(str(args.output / "mobile_sam_decoder.mlpackage"))
    # Basic export parity on Mac, not a food-accuracy benchmark. Fail on NaNs/errors.
    actual_embedding = encoder_model.predict({"image": image.numpy()})["image_embeddings"]
    actual = decoder_model.predict({"image_embeddings": actual_embedding,
        "sparse_embeddings": sparse.numpy(), "dense_embeddings": dense.numpy()})
    np.testing.assert_allclose(actual_embedding, embedding.numpy(), atol=0.15, rtol=0.1)
    np.testing.assert_allclose(actual["masks"], expected_masks.numpy(), atol=0.5, rtol=0.15)
    np.testing.assert_allclose(actual["iou_predictions"], expected_scores.numpy(), atol=0.05, rtol=0.1)
    print("PASS: converted packages and basic CPU/Core ML parity. Real-photo/device validation still required.")


if __name__ == "__main__":
    main()

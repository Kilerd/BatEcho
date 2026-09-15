import Foundation

extension FireRedASR2Config {
    /// Validate before allocating tensors; voicer downloads one pinned model.
    func validateForVoicer() throws {
        guard modelType == "fireredasr2", idim == 80, odim == 8667, dModel == 1280,
              sosID == 3, eosID == 4, padID == 2, blankID == 0,
              encoder.nLayers == 16, encoder.nHead == 20, encoder.dModel == 1280,
              encoder.kernelSize == 33, encoder.peMaxlen == 5000,
              decoder.nLayers == 16, decoder.nHead == 20, decoder.dModel == 1280,
              decoder.peMaxlen == 5000 else {
            throw LocalASRError.invalidInput("Unsupported FireRed configuration. Prepare the model again.")
        }
    }
}

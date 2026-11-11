# LocalAIPortal

An iPhone app that runs AI models entirely on the device: chat with local language models and create or edit images with Stable Diffusion. The only network use is searching Hugging Face and downloading the models you choose.

## What it does

- **Chat**: runs MLX-format language models from Hugging Face, with streaming replies, saved conversations, an editable system prompt, and temperature, top-p, repetition and length controls.
- **Create**: text-to-image with Core ML Stable Diffusion models (1.x, 2.x and SDXL), negative prompts, steps, prompt strength and seeds.
- **Edit**: start from a photo (image-to-image) and optionally paint the area that should change; the rest of the photo is kept.
- **Models**: search Hugging Face inside the app, see each download's size, download, resume and delete.
- **No added filtering**: the app adds no prompt or output filters of its own. A model's bundled image safety filter is off unless you turn it on in Settings.

## Not in this version

- **LoRA add-ons.** Core ML models are compiled ahead of time and cannot take a LoRA at run time. Use a model that already has the style merged in.
- **GGUF chat models.** Only MLX-format models load. Most popular models have an MLX conversion (search the name plus "mlx").
- **True inpainting models.** Painted-area editing runs image-to-image and then blends the result into your photo.
- **Background downloads.** Keep the app open while a model downloads; an interrupted download continues from the last finished file.

## Building it without a Mac

The app is compiled on GitHub's Mac servers and delivered to the phone through TestFlight. This repository holds only the source. The build workflow lives in `srgtcauliflour/ImJustHereForGithubActions`, because that is where the Apple API key secrets (`APPLE_KEY_ID`, `APPLE_ISSUER_ID`, `APPLE_API_PRIVATE_KEY`) are stored, and GitHub does not share secrets between repositories.

1. In that repository open **Actions** → **LocalAIPortal TestFlight** → **Run workflow**. The bundle ID defaults to `com.srgtcauliflour.localaiportal`.
2. The first run registers the bundle ID with Apple and then stops, asking for an app record. Create it at appstoreconnect.apple.com → **Apps** → **+** → **New App**: platform iOS, any free name, that bundle ID, any SKU.
3. Run the workflow again. A full build takes roughly 20 to 40 minutes. If it fails, the run summary lists the compile errors and the full log is attached as `localaiportal-build-log`.
4. In App Store Connect open the app → **TestFlight** → **Internal Testing**, create a group and add yourself. Install Apple's **TestFlight** app on the iPhone; the build appears a few minutes after the workflow finishes.

Each run signs with a certificate created for that run and revoked when it ends, so no signing material is stored in either repository. The API key needs the Admin or App Manager role for this. If the account already holds the maximum number of distribution certificates, revoke an unused one first.

TestFlight builds stop working after 90 days. Run the workflow again to get a fresh one.

## Using it

1. **Models** tab → pick **Chat** or **Image** → search → open a result → **Download**.
2. For images choose a version marked **Built for iPhone** (split-einsum). The first load of an image model takes a few minutes while iOS prepares it.
3. For chat, 4-bit models up to about 8B parameters suit a 12 GB iPhone. Larger ones may be closed by iOS.
4. Only one model is kept in memory at a time; switching tabs to generate swaps them.

Some models on Hugging Face ask you to accept terms first. Accept them on the website, create a read token there, and paste it into **Settings**.

## How it is put together

- `App/` – SwiftUI source.
- `Packages/StableDiffusion/` – Apple's `ml-stable-diffusion` Swift library (MIT-style licence, see `LICENSE.md` there) with the Stable Diffusion 3 files removed.
- `project.yml` – XcodeGen project definition; the Xcode project is generated during the build.
- `fastlane/Fastfile` – signing, build and upload, run by the workflow in the Actions repository.

Chat uses [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) with the tokenizer from [swift-transformers](https://github.com/huggingface/swift-transformers).

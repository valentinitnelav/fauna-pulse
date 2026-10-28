# Tutorial: find and name animals in a video, on your phone

Try FaunaPulse with two short public-domain videos: a honey bee on a pumpkin flower, and two
white-tailed deer at a trail camera. The phone finds the animals in every frame (detection),
follows each one as a track ID (tracking), then names it (identification). Everything runs on
the phone. Only the AI models need the internet, once, to download them.

## Video tutorials

<a href="https://www.youtube.com/watch?v=Ql_NyHM_RQA"><img src="https://i.ytimg.com/vi/Ql_NyHM_RQA/hqdefault.jpg" alt="Video tutorial on YouTube: find and name insects in a video" width="300"></a> &nbsp;&nbsp; <a href="https://www.youtube.com/watch?v=ScNR98OW6T0"><img src="https://i.ytimg.com/vi/ScNR98OW6T0/hqdefault.jpg" alt="Video tutorial on YouTube: find and name mammals in a video" width="300"></a>

- Insects: [find and name insects in a video](https://www.youtube.com/watch?v=Ql_NyHM_RQA) (about 70 s)
- Mammals: [find and name mammals in a video](https://www.youtube.com/watch?v=ScNR98OW6T0) (about 70 s)

The steps below are the same as in the videos. Airplane mode is on in the videos only to show
that FaunaPulse works without internet, for example in the field.

## 1. Download the demo videos

On the phone, open the
[FaunaPulse demo videos](https://huggingface.co/datasets/Valen-Peregrine/faunapulse-demo-videos)
on Hugging Face, go to [*Files and versions*](https://huggingface.co/datasets/Valen-Peregrine/faunapulse-demo-videos/tree/main),
tap a file name, then the download button. The videos land in the phone's Download folder.

| File | What it shows | Size | Try it with |
|---|---|---|---|
| `Pumpkin1080_square_realtime.mp4` | a honey bee on a pumpkin flower | 8.3 MB | insectDCT detector, then BioCLIP 2 with the European pollinator names |
| `White_tailed_Deer_square.mp4` | two white-tailed deer at a trail camera | 19.2 MB | MegaDetector V6, then BioCLIP 2 with the mammal and bird names |

## 2. Download the AI models (once, with internet)

On Home, tap **AI models** at the bottom (screen *Download & import models*) and download:

- **insectDCT detector** (19 MB): finds insects on flowers. For the bee video.
- **MegaDetector V6** (2.5 MB): finds mammals and birds. For the deer video.
- **BioCLIP 2** (609 MB), with the name lists *Flies, bees and wasps, beetles, butterflies and
  moths of Europe* (57 MB) and *Mammals and birds of the world* (28 MB).

BioCLIP 2 is large: use Wi-Fi. After this, FaunaPulse needs no internet.

## 3. Import a video

1. On Home, tap **Import videos…**. Android's picker shows the videos of your gallery.
2. Open its menu (three dots), tap **Browse…**, open the Download folder and pick the video.
3. Tap **Import 1 clip**. FaunaPulse makes a new session that holds the video.

## 4. Find and name the animals

1. Tap **Find animals in these videos**.
2. **Detection model**: the insectDCT detector for the bee, MegaDetector V6 for the deer.
3. Switch on **Also identify them**. Check that the model is BioCLIP 2 and choose the name list
   (European pollinators for the bee, mammals and birds for the deer).
4. Tap **Analyze**.

The detector checks every frame and the tracker follows each animal as a track ID. Then
BioCLIP 2 names each track ID from its photos. On a Xiaomi 11T Pro the bee video took under two
minutes and the deer video under half a minute; slower phones need longer. Keep FaunaPulse on
the screen until it ends: naming needs a lot of the phone's memory, and in the background
Android may make it wait or close the app.

## 5. Read the results

- Bee: one track ID, *Apis mellifera* (western honey bee), 94 %.
- Deer: two track IDs, *Odocoileus virginianus* (white-tailed deer), 96 %.

Tap the name, then a track ID: you see every rank from kingdom to species with its
percentage, and the photo with the animal's box. On another phone the percentages may differ a
little.

Extra details about each step: [Video Analysis](VIDEO_ANALYSIS.md) and
[Identify organisms](IDENTIFICATION.md).

## Credits

The videos are public domain (works of US federal employees), cropped to the square that
FaunaPulse analysed: the bee is USDA footage by Kirsten Strough, shown at natural speed (the
original is 2x slow motion); the deer video is by Kari Cieszkiewicz / USFWS, National Elk
Refuge. Sources and exact changes are on the
[dataset page](https://huggingface.co/datasets/Valen-Peregrine/faunapulse-demo-videos). The
agencies do not endorse FaunaPulse.

Who made each AI model, its licence and how to cite it are on its model card in the
[FaunaPulse models collection](https://huggingface.co/collections/Valen-Peregrine/faunapulse).

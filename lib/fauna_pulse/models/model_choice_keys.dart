// FaunaPulse (round 278): the saved choices of the screens that run a model,
// in one place, so the "What do you want to watch?" page ("Use them from now
// on", models/models_on_phone.dart) writes the same keys the screens read.

const kAnalysisModelPref = 'analysis_model'; // Find animals in photos: the model's path
const kVideoAnalysisModelPref = 'video_analysis_model'; // Find animals in videos: the model's path
const kIdentifyModelPref = 'identify_model'; // Identify: the model's file name
const kIdentifyPackPref = 'identify_pack'; // Identify: the name list's file name
const kSessionConfigPref = 'faunapulse_session_config'; // the camera's settings (JSON), with the model's path
const kWatchChoicePrefPrefix = 'watch_choice_'; // + answer id: the models used last for that answer (file names)

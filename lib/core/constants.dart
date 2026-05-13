const String kServerHost = 'talkia.laravas.com';
const String kServerWsUrl = 'wss://$kServerHost/ws';
const String kOtaBaseUrl = 'https://ota.laravas.com';
const String kOtaVersionUrl = '$kOtaBaseUrl/talkia-version.json';
const String kOtaApkUrl = '$kOtaBaseUrl/talkia-latest.apk';
const int kAppBuild = 1;

// Audio PCM config
const int kSampleRate = 16000;
const int kNumChannels = 1;
const int kBitsPerSample = 16;
// ~60ms de audio por chunk
const int kAudioChunkMs = 60;

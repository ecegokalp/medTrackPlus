/* ===========================================================================
 *  MAX98357A (I2S) ile GERCEK SES (MP3) CALMA - ESP32-S3
 * ---------------------------------------------------------------------------
 *  DFPlayer YOK. Ses (alarm_tr.mp3) dogrudan koda gomulu (alarm_tr_mp3.h).
 *  ESP8266Audio kutuphanesi MP3'u cozer, MAX98357A'ya I2S ile basar.
 *  SD kart / WiFi / filesystem GEREKMEZ -> demoda %100 offline calisir.
 *
 *  GEREKLI KUTUPHANE (Library Manager'dan kur):
 *    "ESP8266Audio"  (yazar: Earle Philhower)  -> ESP32'de de calisir.
 *    En guncel surumu kur (ESP32 Arduino core 3.x uyumu icin).
 *
 *  BAGLANTI:
 *    MAX98357A   ->  ESP32-S3
 *      VIN   ->  5V rayi
 *      GND   ->  GND (ORTAK!)
 *      DIN   ->  GPIO15
 *      BCLK  ->  GPIO16
 *      LRC   ->  GPIO17
 *      GAIN  ->  bos birak (varsayilan 9dB) ; daha yuksek ses icin GND'ye
 *      SD    ->  bos birak (etkin). SES GELMEZSE 3V3'e baglayip dene.
 *      +  -  ->  hoparlor (kutup farketmez)
 * =========================================================================== */

#include <Arduino.h>
#include "AudioFileSourcePROGMEM.h"
#include "AudioGeneratorWAV.h"
#include "AudioOutputI2S.h"
#include "alarm_tr_wav.h"   // kayipsiz WAV (mono 22050 Hz 16-bit)

#define I2S_BCLK 16
#define I2S_LRC  17
#define I2S_DIN  15

AudioFileSourcePROGMEM *file = nullptr;
AudioGeneratorWAV      *wav  = nullptr;
AudioOutputI2S         *out  = nullptr;

void cleanup() {
  if (wav)  { if (wav->isRunning()) wav->stop(); delete wav;  wav  = nullptr; }
  if (file) { delete file; file = nullptr; }
  if (out)  { delete out;  out  = nullptr; }
}

void startPlay() {
  cleanup();
  file = new AudioFileSourcePROGMEM(alarm_tr_wav, alarm_tr_wav_len);
  out  = new AudioOutputI2S();
  out->SetPinout(I2S_BCLK, I2S_LRC, I2S_DIN);
  out->SetOutputModeMono(true);   // mono sesi her iki I2S kanalina ver
  out->SetGain(0.7);              // 0.0 .. 1.0  ses seviyesi
  wav  = new AudioGeneratorWAV();
  wav->begin(file, out);
  Serial.println(">>> Calmaya basladi (alarm_tr, WAV).");
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=== MAX98357A MP3 TEST ===");
  Serial.println("ESP8266Audio ile alarm_tr.mp3 calinacak.");
  startPlay();
}

void loop() {
  if (wav && wav->isRunning()) {
    if (!wav->loop()) {          // parca bitti
      wav->stop();
      Serial.println("Parca bitti. 2 sn sonra tekrar...");
      delay(2000);
      startPlay();
    }
  }
}

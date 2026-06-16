/* ===========================================================================
 *  HOPARLOR (SPEAKER) TON TESTI - ESP32-S3
 * ---------------------------------------------------------------------------
 *  ESP32-S3'te DAC yok; MP3 calamayiz. Bu test hoparlorun SAGLAM olup
 *  olmadigini PWM tonu (bip) ile kontrol eder.
 *
 *  BAGLANTI - Secenek A (transistor ile, yuksek ses, 5V):
 *    ESP GPIO5 -> 1k -> NPN BASE (2N2222/BC547/S8050)
 *    Hoparlor ucu1 -> 5V rayi
 *    Hoparlor ucu2 -> transistor COLLECTOR
 *    transistor EMITTER -> GND
 *
 *  BAGLANTI - Secenek B (transistor yoksa, kisik ses):
 *    ESP GPIO5 -> 100 ohm -> Hoparlor -> GND
 *    (Direncsiz BAGLAMA - pini yakar.)
 *
 *  NOT: Bu gecici bir testtir. Gercek voice anonslari DFPlayer + SD karttan
 *  calinacak (asil tasarim). Bu sadece hoparlor ses cikariyor mu kontrolu.
 * =========================================================================== */

#define SPK_PIN 5

void beep(int freq, int ms) {
  tone(SPK_PIN, freq);   // ESP32 Arduino core tone() destekler
  delay(ms);
  noTone(SPK_PIN);
}

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(SPK_PIN, OUTPUT);
  Serial.println("\n=== HOPARLOR TON TESTI (GPIO5) ===");
  Serial.println("Asagidaki bip dizisini duymalisin.");
}

void loop() {
  Serial.println(">> Bip 1 (1000 Hz)");
  beep(1000, 300);
  delay(200);

  Serial.println(">> Bip 2 (1500 Hz)");
  beep(1500, 300);
  delay(200);

  Serial.println(">> Kucuk melodi (ilac zamani benzeri)");
  beep(880, 180); delay(60);
  beep(1175, 180); delay(60);
  beep(1568, 300);
  delay(1500);

  Serial.println("--- tekrar ---\n");
}

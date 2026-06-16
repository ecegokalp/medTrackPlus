/* ===========================================================================
 *  LED TEST - 4 bacakli RGB LED'i tek tek dene
 * ---------------------------------------------------------------------------
 *  Harici LED'in dogru bagli mi diye kontrol icin BASIT test.
 *  Ana koddaki PWM/provisioning karmasi yok; sadece ac/kapa.
 *
 *  Baglanti (ana koddaki ile ayni):
 *    R bacak  -> 220 ohm -> GPIO 42
 *    G bacak  -> 220 ohm -> GPIO 47
 *    B bacak  -> 220 ohm -> GPIO 46
 *    Ortak    -> GND  (ortak KATOT ise)   <-- once bunu dene
 *               veya 3V3 (ortak ANOT ise)
 *
 *  Bu test ortak KATOT varsayar (pin HIGH = renk yanar).
 *  Hicbir renk yanmazsa: ortak bacagi 3V3'e al ve asagidaki
 *  ON/OFF degerlerini ters cevir (ANODE=true yap).
 * =========================================================================== */

#define LED_R 42
#define LED_G 47
#define LED_B 46

// Ortak ANOT ise true yap (ortak bacak 3V3'e bagli). Ortak KATOT ise false.
const bool ANODE = false;

inline void setPin(int pin, bool on) {
  // ortak katotta: on => HIGH ; ortak anotta: on => LOW
  digitalWrite(pin, ANODE ? !on : on);
}

void allOff() { setPin(LED_R,false); setPin(LED_G,false); setPin(LED_B,false); }

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(LED_R, OUTPUT);
  pinMode(LED_G, OUTPUT);
  pinMode(LED_B, OUTPUT);
  allOff();
  Serial.println("\n=== LED TEST BASLADI ===");
  Serial.println("Ortak bacak: " + String(ANODE ? "3V3 (anot)" : "GND (katot)"));
}

void loop() {
  Serial.println(">> KIRMIZI (GPIO42) yanmali");
  allOff(); setPin(LED_R, true); delay(1500);

  Serial.println(">> YESIL (GPIO47) yanmali");
  allOff(); setPin(LED_G, true); delay(1500);

  Serial.println(">> MAVI (GPIO46) yanmali");
  allOff(); setPin(LED_B, true); delay(1500);

  Serial.println(">> HEPSI (beyaz) yanmali");
  setPin(LED_R,true); setPin(LED_G,true); setPin(LED_B,true); delay(1500);

  Serial.println(">> HEPSI KAPALI");
  allOff(); delay(1000);
  Serial.println("--- tekrar ---\n");
}

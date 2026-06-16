/* ===========================================================================
 *  DFPlayer TEST v2  -  KLON / ACK-BYPASS
 * ---------------------------------------------------------------------------
 *  3 olcum dogru (5V var, GND ortak, RX/TX capraz) ama "YANIT YOK" cikiyorsa:
 *  modul buyuk ihtimalle KLON ve baslatmada ACK cevabi donmuyor.
 *  Bu test ACK beklemeyi KAPATIR ve dogrudan calmayi dener.
 *
 *  Baglanti (yuva ALTTA, sag kenar):
 *    DFPlayer VCC  -> 5V rayi
 *    DFPlayer GND  -> ortak GND
 *    ESP GPIO17 (TX) -> (1k varsa) -> DFPlayer RX
 *    DFPlayer TX     -> ESP GPIO18 (RX)
 *    Hoparlor -> SPK_1 / SPK_2
 *
 *  KART: kokte 0001.mp3 (FAT32).
 * =========================================================================== */

#include <DFRobotDFPlayerMini.h>

#define DF_TX 17   // ESP -> DFPlayer RX
#define DF_RX 18   // DFPlayer TX -> ESP

HardwareSerial dfSerial(1);
DFRobotDFPlayerMini df;

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n=== DFPlayer TEST v2 (ACK bypass) ===");

  dfSerial.begin(9600, SERIAL_8N1, DF_RX, DF_TX);
  delay(2500);   // modulun acilmasi + SD karti okumasi icin BOL zaman

  Serial.println("begin(isACK=false, doReset=false) deneniyor...");
  bool ok = df.begin(dfSerial, /*isACK=*/false, /*doReset=*/false);
  if (ok) Serial.println(">>> begin OK");
  else    Serial.println(">>> begin false dondu - KLON olabilir, YINE DE calmayi deniyoruz");

  delay(500);
  df.volume(28);          // 0..30
  delay(300);
  Serial.println(">>> df.play(1) gonderildi -> HOPARLORDEN SES GELMELI");
  df.play(1);
}

void loop() {
  // DFPlayer'dan ESP'ye gelen HAM baytlari goster.
  // Burada bayt goruyorsan: TX teli SAGLAM ve modul CANLI demektir.
  while (dfSerial.available()) {
    uint8_t b = dfSerial.read();
    Serial.print("DF->ESP ham bayt: 0x");
    if (b < 16) Serial.print("0");
    Serial.println(b, HEX);
  }
  delay(80);
}

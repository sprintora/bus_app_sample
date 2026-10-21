/*
  Bus RFID unit: ESP32 + RC522 only.

  - Reads student cards (RC522 over SPI).
  - Sends every tap to the driver's phone over Bluetooth Low Energy.
  - Keeps unacknowledged taps in RAM and re-sends them until the phone
    confirms, so taps are not lost if Bluetooth drops for a moment.
  - No GPS, no internet, no storage: the phone does all of that.

  Libraries (Arduino Library Manager): "MFRC522" by GithubCommunity
  Board: "ESP32 Dev Module" (ESP32 Arduino core 2.x or 3.x).

  Wiring (RC522 -> ESP32), power the RC522 from 3.3 V:
    SDA(SS) -> GPIO 5     SCK -> GPIO 18    MOSI -> GPIO 23
    MISO    -> GPIO 19    RST -> GPIO 22    3.3V -> 3V3    GND -> GND
  Status LED: the on-board LED (GPIO 2).
    fast blink = RC522 not found, slow blink = waiting for phone,
    off = phone connected, short flash = tap acknowledged by the phone.
*/

#include <SPI.h>
#include <MFRC522.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SS_PIN  5
#define RST_PIN 22
#define LED_PIN 2

#define SERVICE_UUID "7a5f0001-3b1c-4f6e-9d2a-5c1e8b7a0001"
#define TX_UUID      "7a5f0002-3b1c-4f6e-9d2a-5c1e8b7a0001"  // notify -> phone
#define RX_UUID      "7a5f0003-3b1c-4f6e-9d2a-5c1e8b7a0001"  // phone -> unit

MFRC522 rfid(SS_PIN, RST_PIN);

struct TapEvent {
  bool used;
  bool sentOnce;
  uint16_t seq;
  uint32_t tapMs;
  uint32_t lastSentMs;
  uint8_t len;
  uint8_t uid[10];
};

const int MAX_EVENTS = 64;
TapEvent events[MAX_EVENTS];
portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

uint16_t bootId;
uint16_t nextSeq = 1;
volatile bool clientConnected = false;
volatile uint32_t ackFlashUntil = 0;
bool readerOk = false;
BLECharacteristic* txChar = nullptr;

// ---------------------------------------------------------------- BLE ------
class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override { clientConnected = true; }
  void onDisconnect(BLEServer* s) override {
    clientConnected = false;
    BLEDevice::startAdvertising();
  }
};

// Phone -> unit: [1, bootLo, bootHi, seqLo, seqHi] = "tap received"
class RxCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    auto v = c->getValue();
    if (v.length() >= 5 && (uint8_t)v[0] == 1) {
      uint16_t boot = (uint8_t)v[1] | ((uint8_t)v[2] << 8);
      uint16_t seq  = (uint8_t)v[3] | ((uint8_t)v[4] << 8);
      if (boot == bootId) {
        portENTER_CRITICAL(&mux);
        for (int i = 0; i < MAX_EVENTS; i++) {
          if (events[i].used && events[i].seq == seq) events[i].used = false;
        }
        portEXIT_CRITICAL(&mux);
        ackFlashUntil = millis() + 120;
      }
    }
  }
};

void setupBle() {
  uint64_t mac = ESP.getEfuseMac();
  char name[24];
  snprintf(name, sizeof(name), "BusRFID-%02X%02X",
           (unsigned)((mac >> 32) & 0xFF), (unsigned)((mac >> 40) & 0xFF));

  BLEDevice::init(name);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCb());

  BLEService* service = server->createService(SERVICE_UUID);

  txChar = service->createCharacteristic(TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());

  BLECharacteristic* rxChar = service->createCharacteristic(
      RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rxChar->setCallbacks(new RxCb());

  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.print("BLE ready as ");
  Serial.println(name);
}

// ------------------------------------------------------------ RFID ---------
bool checkReader() {
  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  return (v != 0x00 && v != 0xFF);
}

void addEvent(const uint8_t* uid, uint8_t len) {
  uint32_t now = millis();
  portENTER_CRITICAL(&mux);
  int slot = -1;
  for (int i = 0; i < MAX_EVENTS; i++) {
    if (!events[i].used) { slot = i; break; }
  }
  if (slot < 0) {  // buffer full: replace the oldest tap
    uint32_t oldestAge = 0;
    for (int i = 0; i < MAX_EVENTS; i++) {
      uint32_t age = now - events[i].tapMs;
      if (age >= oldestAge) { oldestAge = age; slot = i; }
    }
  }
  TapEvent& e = events[slot];
  e.used = true;
  e.sentOnce = false;
  e.seq = nextSeq++;
  e.tapMs = now;
  e.lastSentMs = 0;
  e.len = len;
  memcpy(e.uid, uid, len);
  portEXIT_CRITICAL(&mux);
}

void readCard() {
  static uint32_t lastTry = 0;
  static uint8_t lastUid[10];
  static uint8_t lastLen = 0;
  static uint32_t lastAt = 0;

  if (!readerOk) {
    if (millis() - lastTry > 3000) {
      lastTry = millis();
      rfid.PCD_Init();
      readerOk = checkReader();
    }
    return;
  }

  if (!rfid.PICC_IsNewCardPresent()) return;
  if (!rfid.PICC_ReadCardSerial()) return;

  uint8_t len = rfid.uid.size;
  if (len > 10) len = 10;
  bool repeat = (len == lastLen) && (memcmp(lastUid, rfid.uid.uidByte, len) == 0) &&
                (millis() - lastAt < 3000);
  memcpy(lastUid, rfid.uid.uidByte, len);
  lastLen = len;
  lastAt = millis();

  if (!repeat) addEvent(rfid.uid.uidByte, len);

  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}

// ------------------------------------------------------- send to phone -----
// Tap packet : [1, bootLo, bootHi, seqLo, seqHi, age0, age1, age2, age3, uidLen, uid...]
void sendPending() {
  static uint32_t lastTx = 0;
  if (!clientConnected) return;
  uint32_t now = millis();
  if (now - lastTx < 80) return;

  TapEvent ev;
  bool found = false;
  uint32_t bestAge = 0;

  portENTER_CRITICAL(&mux);
  int pick = -1;
  for (int i = 0; i < MAX_EVENTS; i++) {
    if (!events[i].used) continue;
    bool due = !events[i].sentOnce || (now - events[i].lastSentMs > 2000);
    if (!due) continue;
    uint32_t age = now - events[i].tapMs;
    if (pick < 0 || age >= bestAge) { pick = i; bestAge = age; }
  }
  if (pick >= 0) {
    events[pick].sentOnce = true;
    events[pick].lastSentMs = now;
    ev = events[pick];
    found = true;
  }
  portEXIT_CRITICAL(&mux);

  if (!found) return;

  uint32_t age = now - ev.tapMs;
  uint8_t buf[20];
  buf[0] = 1;
  buf[1] = bootId & 0xFF;
  buf[2] = bootId >> 8;
  buf[3] = ev.seq & 0xFF;
  buf[4] = ev.seq >> 8;
  buf[5] = age & 0xFF;
  buf[6] = (age >> 8) & 0xFF;
  buf[7] = (age >> 16) & 0xFF;
  buf[8] = (age >> 24) & 0xFF;
  buf[9] = ev.len;
  memcpy(buf + 10, ev.uid, ev.len);
  txChar->setValue(buf, 10 + ev.len);
  txChar->notify();
  lastTx = now;
}

// Status packet every 5 s: [2, readerOk, unsentCount, bootLo, bootHi]
void sendHeartbeat() {
  static uint32_t lastHb = 0;
  if (!clientConnected) return;
  uint32_t now = millis();
  if (now - lastHb < 5000) return;
  lastHb = now;

  uint8_t count = 0;
  portENTER_CRITICAL(&mux);
  for (int i = 0; i < MAX_EVENTS; i++) if (events[i].used) count++;
  portEXIT_CRITICAL(&mux);

  uint8_t buf[5] = {2, (uint8_t)(readerOk ? 1 : 0), count,
                    (uint8_t)(bootId & 0xFF), (uint8_t)(bootId >> 8)};
  txChar->setValue(buf, 5);
  txChar->notify();
}

// ------------------------------------------------------------- LED ---------
void updateLed() {
  uint32_t now = millis();
  bool on = false;
  if (now < ackFlashUntil) on = true;
  else if (!readerOk) on = (now / 100) % 2;
  else if (!clientConnected) on = (now / 500) % 2;
  digitalWrite(LED_PIN, on ? HIGH : LOW);
}

// ----------------------------------------------------------- setup/loop ----
void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  bootId = (uint16_t)(esp_random() & 0xFFFF);
  memset(events, 0, sizeof(events));

  SPI.begin();  // default pins: SCK 18, MISO 19, MOSI 23
  rfid.PCD_Init();
  delay(50);
  readerOk = checkReader();
  Serial.println(readerOk ? "RC522 OK" : "RC522 NOT FOUND - check wiring");

  setupBle();
}

void loop() {
  readCard();
  sendPending();
  sendHeartbeat();
  updateLed();
  delay(5);
}

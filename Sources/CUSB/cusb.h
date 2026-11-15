// cusb.h – schlanke IOKit-USB-Schicht (nicht-exklusiv, nur Control-Transfers an Interface 0).
#ifndef CUSB_H
#define CUSB_H
#include <stdint.h>

typedef struct cusb_dev cusb_dev;

// Oeffnet das erste gefundene Geraet mit VID und einer der PIDs (Reihenfolge = Prioritaet).
// NULL, wenn nicht gefunden. *opened_pid (optional) bekommt die PID des geoeffneten Geraets.
// Kein USBDeviceOpen (nicht-exklusiv).
cusb_dev *cusb_open(uint16_t vid, const uint16_t *pids, int npids, uint16_t *opened_pid);
void cusb_close(cusb_dev *d);

// Control-Transfer. Rueckgabe: uebertragene Bytes (>=0) oder negatives IOReturn-Low-Word.
int cusb_control(cusb_dev *d, uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
                 void *data, uint16_t length, uint32_t timeout_ms);

// Hotplug: cb(ctx, 1) bei Anstecken, cb(ctx, 0) bei Abziehen; sofort auch fuer bereits angeschlossenes Geraet.
// Laeuft auf dem Main-Run-Loop. Rueckgabe 0 = ok.
typedef void (*cusb_hotplug_cb)(void *ctx, int attached);
// Je PID eine eigene Benachrichtigung (gleicher Callback).
int cusb_watch(uint16_t vid, const uint16_t *pids, int npids, cusb_hotplug_cb cb, void *ctx);

#endif

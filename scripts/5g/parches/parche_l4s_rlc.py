#!/usr/bin/env python3
# parche_l4s_rlc.py v2 - TFG L4S (J. Bedoya): marcado L4S y registro asíncrono en la RLC AM de OAI (commit 1143f75)
# TFG_L4S_UMBRAL_US (0 = sin marcado), TFG_L4S_CTRL (fichero con el umbral, releído cada s),
# TFG_RLC_LOG (CSV), TFG_LOG_MS (periodo, 10 ms). Sin E/S de ficheros en el camino de la RLC.
import sys, os

src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/oai-src')
H = os.path.join(src, 'openair2/LAYER2/nr_rlc/nr_rlc_entity_am.h')
C = os.path.join(src, 'openair2/LAYER2/nr_rlc/nr_rlc_entity_am.c')


def sustituir(txt, viejo, nuevo, nombre):
    n = txt.count(viejo)
    if n != 1:
        sys.exit(f'ERROR: el ancla "{nombre}" aparece {n} veces (se esperaba 1). ¿Commit distinto?')
    return txt.replace(viejo, nuevo)


h = open(H).read()
if 'tfg_marks' in h:
    sys.exit('El parche ya estaba aplicado en la cabecera (haz git checkout de los ficheros).')
h = sustituir(h, '  nr_rlc_sdu_segment_t *retransmit_list;\n} nr_rlc_entity_am_t;',
'''  nr_rlc_sdu_segment_t *retransmit_list;

  /* ---- TFG L4S (J. Bedoya) ---- */
  int      tfg_is_drb;
  uint64_t tfg_last_log_ms;
  uint64_t tfg_ip_pkts;
  uint64_t tfg_l4s_pkts;
  uint64_t tfg_marks;
  uint64_t tfg_soj_sum_us;
  uint64_t tfg_soj_n;
  uint64_t tfg_soj_max_us;
} nr_rlc_entity_am_t;''', 'fin de nr_rlc_entity_am_t')
c = open(C).read()

bloque = r"""#include "common/utils/assertions.h"

/* ======================================================================
 * TFG L4S (J. Bedoya): marcado L4S en la RLC del gNB + registro periódico.
 * Versión 2: NINGUNA operación de fichero en el camino de la RLC. Las muestras
 * se guardan en un anillo en memoria y un hilo aparte (prioridad normal) las
 * escribe en disco cada 200 ms y relee el umbral cada segundo.
 * ====================================================================== */
#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>

typedef struct {
  uint64_t t_us, hol_us, soj_media_us, soj_max_us, n_deq, ip, l4s, marcas;
  uint32_t ent, tx_pdu, retx_pdu, descartes, sdu_rx, umbral_us;
  int tx_next, tx_next_ack, poll_sn, en_vuelo, cola, bs_tx, bs_retx, tx_max, rx_next, rx_next_highest;
} tfg_muestra_t;

#define TFG_RING 16384
static tfg_muestra_t tfg_ring[TFG_RING];
static uint64_t tfg_head = 0, tfg_tail = 0, tfg_perdidas = 0;

static int      tfg_cfg_init = 0;
static uint64_t tfg_umbral_us = 0;
static int      tfg_log_ms = 10;
static FILE    *tfg_log = NULL;
static const char *tfg_ctrl = NULL;

static void *tfg_hilo(void *arg)
{
  (void)arg;
  int ciclo = 0;
  for (;;) {
    usleep(200000);
    uint64_t h = __atomic_load_n(&tfg_head, __ATOMIC_ACQUIRE);
    if (tfg_log != NULL) {
      while (tfg_tail < h) {
        tfg_muestra_t *m = &tfg_ring[tfg_tail % TFG_RING];
        fprintf(tfg_log, "%lu,%x,%d,%d,%d,%d,%d,%d,%d,%d,%lu,%lu,%lu,%lu,%u,%u,%u,%u,%lu,%lu,%lu,%d,%d,%u\n",
                (unsigned long)m->t_us, m->ent, m->tx_next, m->tx_next_ack, m->poll_sn, m->en_vuelo,
                m->cola, m->bs_tx, m->bs_retx, m->tx_max, (unsigned long)m->hol_us,
                (unsigned long)m->soj_media_us, (unsigned long)m->soj_max_us, (unsigned long)m->n_deq,
                m->tx_pdu, m->retx_pdu, m->descartes, m->sdu_rx,
                (unsigned long)m->ip, (unsigned long)m->l4s, (unsigned long)m->marcas,
                m->rx_next, m->rx_next_highest, m->umbral_us);
        tfg_tail++;
      }
      __atomic_store_n(&tfg_tail, tfg_tail, __ATOMIC_RELEASE);
      fflush(tfg_log);
    } else {
      __atomic_store_n(&tfg_tail, h, __ATOMIC_RELEASE);
    }
    if (tfg_ctrl != NULL && ++ciclo % 5 == 0) {
      FILE *f = fopen(tfg_ctrl, "r");
      if (f != NULL) {
        unsigned long v;
        if (fscanf(f, "%lu", &v) == 1 && v != __atomic_load_n(&tfg_umbral_us, __ATOMIC_RELAXED)) {
          __atomic_store_n(&tfg_umbral_us, (uint64_t)v, __ATOMIC_RELAXED);
          LOG_I(RLC, "[TFG] L4S: umbral de marcado cambiado a %lu us\n", v);
        }
        fclose(f);
      }
    }
  }
  return NULL;
}

static void tfg_config(void)
{
  if (tfg_cfg_init)
    return;
  tfg_cfg_init = 1;
  const char *e = getenv("TFG_L4S_UMBRAL_US");
  if (e != NULL)
    tfg_umbral_us = strtoull(e, NULL, 10);
  e = getenv("TFG_LOG_MS");
  if (e != NULL && atoi(e) > 0)
    tfg_log_ms = atoi(e);
  tfg_ctrl = getenv("TFG_L4S_CTRL");
  if (tfg_ctrl != NULL && !*tfg_ctrl)
    tfg_ctrl = NULL;
  const char *f = getenv("TFG_RLC_LOG");
  if (f != NULL && *f) {
    tfg_log = fopen(f, "w");
    if (tfg_log != NULL)
      fprintf(tfg_log, "t_us,ent,tx_next,tx_next_ack,poll_sn,en_vuelo,cola_bytes,bs_tx,bs_retx,tx_max,"
                       "hol_us,soj_media_us,soj_max_us,n_deq,tx_pdu,retx_pdu,descartes_llena,sdu_rx,"
                       "ip_pkts,l4s_pkts,marcas,rx_next,rx_next_highest,umbral_us\n");
  }
  if (tfg_log != NULL || tfg_ctrl != NULL) {
    pthread_attr_t at;
    struct sched_param sp = {0};
    pthread_t th;
    pthread_attr_init(&at);
    pthread_attr_setinheritsched(&at, PTHREAD_EXPLICIT_SCHED);
    pthread_attr_setschedpolicy(&at, SCHED_OTHER);
    pthread_attr_setschedparam(&at, &sp);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, tfg_hilo, NULL) != 0)
      LOG_E(RLC, "[TFG] no se pudo crear el hilo de registro\n");
    pthread_attr_destroy(&at);
  }
  LOG_I(RLC, "[TFG] L4S v2: umbral de marcado %lu us (0 = sin marcado); registro RLC %s cada %d ms (asíncrono)\n",
        (unsigned long)tfg_umbral_us, tfg_log ? f : "desactivado", tfg_log_ms);
}

static uint16_t tfg_csum(const uint8_t *ip, int hl)
{
  uint32_t s = 0;
  for (int i = 0; i + 1 < hl; i += 2)
    s += ((uint32_t)ip[i] << 8) | ip[i + 1];
  while (s >> 16)
    s = (s & 0xffff) + (s >> 16);
  return (uint16_t)~s;
}

static uint8_t *tfg_find_ip(uint8_t *p, int n)
{
  for (int off = 2; off <= 4; off++) {
    if (off + 20 > n)
      return NULL;
    uint8_t *ip = p + off;
    int hl = (ip[0] & 0x0f) * 4;
    if ((ip[0] >> 4) != 4 || hl < 20 || off + hl > n)
      continue;
    int tot = (ip[2] << 8) | ip[3];
    if (tot < hl || off + tot > n)
      continue;
    if (tfg_csum(ip, hl) != 0)
      continue;
    return ip;
  }
  return NULL;
}

static void tfg_on_dequeue(nr_rlc_entity_am_t *e, nr_rlc_sdu_segment_t *seg)
{
  if (seg->so != 0)
    return;
  uint8_t *ip = tfg_find_ip((uint8_t *)seg->sdu->data, seg->sdu->size);
  if (ip == NULL)
    return;
  uint64_t now = time_average_now();
  uint64_t w = (now > seg->sdu->time_of_arrival) ? now - seg->sdu->time_of_arrival : 0;
  e->tfg_is_drb = 1;
  e->tfg_ip_pkts++;
  e->tfg_soj_sum_us += w;
  e->tfg_soj_n++;
  if (w > e->tfg_soj_max_us)
    e->tfg_soj_max_us = w;
  if ((ip[1] & 0x03) == 0x01) {
    e->tfg_l4s_pkts++;
    uint64_t u = __atomic_load_n(&tfg_umbral_us, __ATOMIC_RELAXED);
    if (u > 0 && w > u) {
      int hl = (ip[0] & 0x0f) * 4;
      ip[1] |= 0x03;
      ip[10] = 0;
      ip[11] = 0;
      uint16_t cs = tfg_csum(ip, hl);
      ip[10] = cs >> 8;
      ip[11] = cs & 0xff;
      e->tfg_marks++;
    }
  }
}

static void tfg_log_line(nr_rlc_entity_am_t *e, uint64_t now_ms)
{
  if (tfg_log == NULL || !e->tfg_is_drb)
    return;
  if (now_ms - e->tfg_last_log_ms < (uint64_t)tfg_log_ms)
    return;
  e->tfg_last_log_ms = now_ms;
  uint64_t h = tfg_head;
  if (h - __atomic_load_n(&tfg_tail, __ATOMIC_ACQUIRE) >= TFG_RING) {
    tfg_perdidas++;
    return;
  }
  tfg_muestra_t *m = &tfg_ring[h % TFG_RING];
  uint64_t now = time_average_now();
  m->t_us = now;
  m->ent = (uint32_t)((uintptr_t)e & 0xffffff);
  m->tx_next = e->tx_next;
  m->tx_next_ack = e->tx_next_ack;
  m->poll_sn = e->poll_sn;
  m->en_vuelo = (e->tx_next - e->tx_next_ack + e->sn_modulus) % e->sn_modulus;
  m->cola = e->tx_size;
  m->bs_tx = e->common.bstatus.tx_size;
  m->bs_retx = e->common.bstatus.retx_size;
  m->tx_max = e->tx_maxsize;
  m->hol_us = (e->tx_list != NULL && now > e->tx_list->sdu->time_of_arrival) ? now - e->tx_list->sdu->time_of_arrival : 0;
  m->soj_media_us = e->tfg_soj_n ? e->tfg_soj_sum_us / e->tfg_soj_n : 0;
  m->soj_max_us = e->tfg_soj_max_us;
  m->n_deq = e->tfg_soj_n;
  m->tx_pdu = e->common.stats.txpdu_pkts;
  m->retx_pdu = e->common.stats.txpdu_retx_pkts;
  m->descartes = e->common.stats.txpdu_dd_pkts;
  m->sdu_rx = e->common.stats.rxsdu_pkts;
  m->ip = e->tfg_ip_pkts;
  m->l4s = e->tfg_l4s_pkts;
  m->marcas = e->tfg_marks;
  m->rx_next = e->rx_next;
  m->rx_next_highest = e->rx_next_highest;
  m->umbral_us = (uint32_t)__atomic_load_n(&tfg_umbral_us, __ATOMIC_RELAXED);
  __atomic_store_n(&tfg_head, h + 1, __ATOMIC_RELEASE);
  e->tfg_soj_sum_us = 0;
  e->tfg_soj_n = 0;
  e->tfg_soj_max_us = 0;
}
/* ================== fin del bloque TFG ================== */
"""
c = sustituir(c, '#include "common/utils/assertions.h"\n', bloque, 'include assertions.h')
c = sustituir(c, '    entity->force_poll = 0;\n  }\n  int ret_size = serialize_sdu(entity, sdu, buffer, size, p);',
              '    entity->force_poll = 0;\n  }\n  tfg_on_dequeue(entity, sdu); /* TFG L4S */\n'
              '  int ret_size = serialize_sdu(entity, sdu, buffer, size, p);', 'serialize_sdu en generate_tx_pdu')
c = sustituir(c, '  if (entity->common.avg_time_is_on)\n    sdu->sdu->time_of_arrival = time_average_now();\n}',
              '  sdu->sdu->time_of_arrival = time_average_now(); /* TFG L4S: siempre */\n}', 'time_of_arrival en recv_sdu')
c = sustituir(c, '  entity->common.stats.rxsdu_pkts++;\n\n  AssertFatal(size <= NR_SDU_MAX',
              '  tfg_config(); /* TFG L4S */\n  entity->common.stats.rxsdu_pkts++;\n\n  AssertFatal(size <= NR_SDU_MAX',
              'inicio de recv_sdu')
c = sustituir(c, '  check_t_reassembly(entity);\n}',
              '  check_t_reassembly(entity);\n\n  tfg_log_line(entity, now); /* TFG L4S */\n}', 'fin de set_time')
open(H, 'w').write(h)
open(C, 'w').write(c)
print('Parche TFG L4S v2 aplicado en', H, 'y', C)

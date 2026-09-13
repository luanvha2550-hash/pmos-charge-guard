# charge-guard.sh — PostmarketOS Battery Server Guard (X00TD / SDM660)

Script POSIX (`/bin/sh`) que transforma um celular com PostmarketOS em servidor 24/7, protegendo a bateria contra degradação e resolvendo automaticamente o bug do charger PM660 (Qualcomm SDM660).

Testado no **ASUS Zenfone Max Pro M1 (X00TD)** rodando **PostmarketOS edge** (Linux 6.17.4-sdm660, aarch64). Roda como serviço systemd.

## O que ele faz

1. **Limita a carga em ~75%** — bateria de lítio em 24/7 sofre ficando em 100%. O script trabalha com uma banda de 70–75%: abaixo disso carrega forte (1,2 A), no alvo derruba a corrente pra ~350 mA e acima de 85% pra 150 mA (efeito "step charging" via `current_max`).
2. **Failsafe** — se a bateria cair a 40% (SAFE_MIN), força carga rápida independente do estado, pra nunca deixar o "servidor" morrer.
3. **Auto-recovery do bug PM660** — o grande diferencial. Veja abaixo.

## O bug do PM660 (e por que isso existe)

No SDM660 mainline, depois de um tempo em step-charging, o firmware do chip PM660 "adormece": o charger continua reportando `status=Charging` e `online=1`, mas a bateria reporta `status=Discharging`. O celular para de carregar e aos poucos **desliga na tomada**. Desplugar e replugar o cabo resolve temporariamente.

**Causa:** bug no driver `qcom-smbx-charger` (built-in no kernel mainline). O firmware para de processar mudanças de `current_max`.

**Solução encontrada (testada):** unbind/rebind do driver via sysfs — simula o efeito de tirar e pôr na tomada, sem tocar no cabo:

```sh
echo "800f000.spmi:pmic@0:charger@1000" > /sys/bus/platform/drivers/qcom-smbx-charger/unbind
sleep 3
echo "800f000.spmi:pmic@0:charger@1000" > /sys/bus/platform/drivers/qcom-smbx-charger/bind
```

O script detecta o bug (charger=Charging + battery=Discharging em leituras consecutivas) e faz o recovery sozinho após 3 leituras com inconsistência, com cooldown de 120s entre tentativas.

### O que NÃO funciona (para não perder tempo)

| Método | Resultado |
|--------|-----------|
| UDC toggle (gadget USB) | ❌ Não resolve |
| DWC3 bind/unbind | ❌ Não resolve |
| Escrever em `online` (sysfs) | ❌ Read-only |
| Reiniciar o serviço charge-guard | ❌ O serviço tá ok, quem buga é o driver |
| **qcom-smbx-charger unbind/rebind** | ✅ **Funciona** |
| Desplugar/replugar fisicamente | ✅ Funciona (mas requer mão humana) |

## Requisitos

- PostmarketOS (testado em edge, kernel 6.17.x) em dispositivo SDM660/SDM636 (Zenfone Max Pro M1, Redmi Note 6/7 etc.)
- Paths sysfs padrão do SDM660 mainline:
  - Charger: `/sys/class/power_supply/pm660-charger/` (knob: `current_max`)
  - Bateria: `/sys/class/power_supply/qcom-battery/`
- systemd (ou adapte o service pro seu init)
- Acesso root (escrever em `/sys/class/...`)

## Instalação

```sh
# 1. Copie o script e o service pro aparelho
scp charge-guard.sh charge-guard.service user@ip-do-aparelho:/tmp/

# 2. No aparelho (como root)
install -m 755 /tmp/charge-guard.sh /usr/local/bin/charge-guard.sh
cp /tmp/charge-guard.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now charge-guard.service

# 3. Acompanhe
journalctl -u charge-guard -f
```

## Configuração (topo do script)

| Variável | Padrão | O que faz |
|----------|--------|-----------|
| `FAST_CHARGE` | 1200000 µA | Corrente de carga rápida (fase de reposição) |
| `STEP_BASE` | 350000 µA | Corrente na banda 75–80% |
| `STEP_MID` | 250000 µA | Corrente na banda 80–85% |
| `STEP_HIGH` | 150000 µA | Corrente >85% |
| `TARGET_TOP` / `TARGET_LOW` | 75 / 70% | Banda alvo (histerese) |
| `SAFE_MIN` | 40% | Abaixo disso força carga rápida |
| `BUG_THRESHOLD` | 3 | Leituras com bug antes do recovery |
| `RECOVERY_COOLDOWN` | 120 s | Intervalo mínimo entre recoveries |

## Limitações / bugs conhecidos

- Na zona de ~80%, a corrente cai pra 250 mA e o sistema pode **oscilar entre charging/discharging**, às vezes disparando o recovery (falso positivo). O cooldown segura o abuso, mas se incomodar, aumente `STEP_MID` pra 300000.
- Os paths sysfs são específicos do SDM660 mainline. Em outros SoCs, ajuste `CHG_DIR`, `BAT_DIR`, `CHG_DRIVER` e `CHG_DEVICE` — o conceito (limitar via `current_max` + reset do driver do charger) se aplica de forma parecida.
- Baterias velhas podem reportar capacidade instável; o failsafe de 40% existe por isso.

## Por que 75%?

Bateria de Li-ion envelhece rápido em duas situações: alta tensão (perto de 100%) e calor. Num servidor que fica na tomada 24/7, segurar a carga na faixa dos 70–75% aumenta muito a vida útil da célula, e o consumo do aparelho é ridículo (~5W, uns R$3-4/mês no Brasil).

---

*Extraído de um Zenfone Max Pro M1 que roda como servidor caseiro desde 2026 (servidor de arquivos, assistente de voz e node Tailscale). Licença: MIT.*
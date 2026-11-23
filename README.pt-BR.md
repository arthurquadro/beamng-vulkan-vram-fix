# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇺🇸 **English version:** [README.md](README.md)

Um mod leve e não-destrutivo (`v1.2.1`) para **BeamNG.drive** que impede o **estouro progressivo de VRAM no Vulkan** e o **transbordamento sob alta VRAM para o "SWAP" na RAM do sistema (`nonLocalUsageBytes`)** — evitando a saturação de VRAM que derruba o FPS para ~10–14 FPS ou gera crashes (quando só mudar uma opção gráfica fazia a VRAM cair temporariamente).

- **Funciona com qualquer veículo e qualquer mapa** — não altera nenhum arquivo de veículo nem do jogo.
- **Funciona em placas AMD, NVIDIA e Intel** (atua apenas no Vulkan; fica inativo automaticamente no DirectX 11 / DirectX 12).
- **100% Lua puro (apenas 2 arquivos pequenos)** — zero conflito com outros mods e carregamento idempotente.
- **Preserva todas as suas configurações gráficas** — você pode mudar gráficos, resolução, Profundidade de Campo (DoF) e espelhos livremente no menu sem quebrar a correção.

---

## Por que Esse Problema Acontece (Causa Raiz)

A análise técnica do executável `BeamNG.drive.x64.exe` (`v0.40.6.0`) revelou por que a VRAM sobe continuamente no Vulkan (enquanto no DirectX 12 fica estável), por que partes do mapa acabam presas no "SWAP" via PCIe e por que mudar qualquer opção gráfica alivia o problema na hora:

1. **Pools internos do Vulkan não são limpos durante a gameplay:** o método `GFXVkDevice::endScene` nunca apara a lista de slabs de transferência de `16 MB` (`"Buffer volatile cpu"` / listas de staging de upload) e retém até `32 × 8 MB` de slabs dinâmicos por bucket na VRAM, além de outros caches internos. Quando você muda uma opção gráfica, o jogo chama `GFXVkWindowTarget::resetModeInternal` → `GFXVkDevice::waitIdle()`, limpando tudo de uma vez.
2. **Coletor automático de VRAM órfão:** o próprio motor do BeamNG já possui uma função de limpeza sob pressão de VRAM (`GFXVkDevice::vtable[+0x108]` em `0x140F10260` → `checkVmaHeapBudgets(0.85f)` em `0x140F0ED80` → `waitIdle()` em `0x140F1A710`) que dispara quando o uso VMA `DEVICE_LOCAL` passa de 85% de `budgetBytes`, quando a memória não-local passa de 1 GiB ou após 5 chamadas. Porém, o **único chamador** dela no binário é `GuiCanvas::repaintUIThrottled()`, que o Lua original só chama durante a **tela de carregamento** (`updateLoadingProgress`), nunca durante a gameplay normal.
3. **Orçamento padrão exagerado do `transientPool`:** a variável interna `$gfx::transientPoolBudgetMB` vem em **`1536 MB`** (1,5 GB), segurando render targets ociosos — algo especialmente pesado em placas de 8 GB sem Resizable BAR (BAR de 256 MB).

---

## Novidades da `v1.2.1` (Ajuste Anti-SWAP & Hotfix de Crash `VK_ERROR_DEVICE_LOST`)

Na `v1.2.0`, disparar limpezas incondicionalmente apenas por `SWAP >= 1032 MB` — mesmo quando a VRAM já estava no piso limpo de `55%–60%` (`~4.040 MB` em uso, `3,68–4,04 GiB` de VRAM física livres) — conflitava com o conjunto de trabalho legítimo do motor no `SWAP` (`~1.015–1.230 MB` de slabs voláteis/transfer staging retidos + `+180–450 MB` de streaming temporário). Repetir `GFXVkDevice::waitIdle()` a cada ~8 segundos com VRAM baixa interrompia uploads assíncronos de `transferAcc->queue.submit`, causando `VK_ERROR_DEVICE_LOST` (`vkGpuCrashBreadcrumbs.cpp:626`).

Ao mesmo tempo, os próprios logs provaram que limpar **apenas quando a VRAM está realmente alta (`≥ 78%` do orçamento VMA junto com `SWAP >= 1032 MB`)** aciona um **`waitIdle()` limpo no 1º pulso** (`0x140F0EEA3`) e recupera **`1.520–1.796 MB` de VRAM vazada por limpeza**, evitando o platô de `~78%–84%`.

### O que a `v1.2.1` corrige:
1. **Exige VRAM elevada na limpeza assistida por SWAP:** `swap_assisted_vram_pressure` só dispara quando **`SWAP >= 1032 MB` E `VMA >= 78,0%`** (além do `vram_pressure` padrão em **`VMA >= 85,2%`**). Com VRAM saudável (`< 78%`), o mod fica 100% ocioso independentemente do tráfego normal de staging no `SWAP`.
2. **Restaura `$gfx::transientPoolBudgetMB = 384 MB` e limpeza em pausa em `72%`:** volta aos valores estáveis e sem crashes da `v1.1.0` (`384 MB` e `72%` em pausa), evitando recriação excessiva de render targets.
3. **Validação estrita apenas por VRAM e pulsos de 1 toque:** só considera a limpeza efetiva se pelo menos **`192 MB` de VRAM** forem liberados (ignorando flutuações de staging no `SWAP`); trava o disparo em **1 pulso** quando `VMA >= 85,2%` ou `SWAP >= 1032 MB`; aumenta o cooldown ativo para **`15 s`** (backoff de `30 s → 90 s`, carência de **`15 s`** pós-carregamento e **`5 s`** após mudar gráficos); e remove os gatilhos agressivos sob VRAM baixa (`swap_growth_preventive`, `wddm_budget_contraction`, `paused_swap_cleanup`, `post_mission_swap_cleanup`, `post_settings_cleanup`).

### Descobertas Anteriores (`v1.2.0` e `v1.1.0`)

- **Visibilidade de `SWAP` não-local (`0x140EFA680` → `0x140EF7C90`):** `Engine.Render.getMemoryInfo()` (`0x140EFBA40`) zera `sharedBytes = 0` em GPUs dedicadas, enquanto `Engine.Platform.getGPUAdaptersInfo()` consulta `VK_EXT_memory_budget` (`nonLocalUsageBytes` / `nonLocalBudgetBytes`). Em `0x140F0EEA3`, `checkVmaHeapBudgets` autoriza limpeza no 1º pulso quando `nonLocalUsageBytes >= 1 GiB`.
- **Callback OOM vazio e inversão de prioridade:** `vku::GenericBuffer` (`0x140EE42DD`) e `vku::GenericImage::create` (`0x14037E22C`) têm callback OOM vazio (`0x1401035E0 = ret 0`), e `VK_EXT_memory_priority` dá `1.0f` a render targets vs `0.75f` ao mapa/texturas — exigindo manter a VRAM abaixo de ~78–85% para o Windows WDDM não empurrar o mapa (`0.75f`) para a RAM via PCIe (`Heap 2`).
- **Alinhamento com orçamento VMA (`v1.1.0`):** `GFXVkDevice::getMemoryInfo` reporta `availableBytes = max(0, budgetBytes - usageBytes)`. Alinhar em `usageBytes / budgetBytes >= 0.852` garante limpeza no 1º pulso em `~198–260 ms`.

---

## O que Este Mod Faz

1. **Reduz `$gfx::transientPoolBudgetMB` de `1536 MB` para `384 MB`** no Vulkan (reaplicado automaticamente ao iniciar mapa ou alterar gráficos, sem mexer em nenhuma opção visual do jogador).
2. **Monitora VRAM e `SWAP` (memória GPU não-local)** via `Engine.Render.getMemoryInfo()` e `Engine.Platform.getGPUAdaptersInfo()`, chamando `Canvas:repaintUIThrottled()` com segurança fora do passe de renderização (`onUpdate`):
   - **Pressão padrão de VMA (`≥ 85,2%` de `budgetBytes`):** aciona `checkVmaHeapBudgets(0.85f)` em **1 único pulso** (`~200–285 ms`).
   - **Pressão de VMA assistida por SWAP (`≥ 78,0%` VMA com `SWAP ≥ 1032 MB`):** aproveita o limiar de `1 GiB` do C++ (`0x140F0EEA3`) para limpar em **1 pulso** antes que o platô de `~78%–84%` empurre assets do mapa para o `SWAP`.
   - **Em pausa:** faz limpeza oportunista apenas quando **`VMA ≥ 72,0%`**.
   - **Cooldowns de segurança e proteção anti-loop:** impõe intervalo mínimo de **`15 s`** após limpezas (**`15 s`** pós-carregamento de mapa e **`5 s`** após mudar gráficos) para não interromper uploads do `transferAcc`; se recuperar `< 192 MB` de VRAM, recua (`30 s → 90 s`).

### Telemetria Comprovada (`beamng.2.log` e `beamng.1.log` — Citybus + 7 Veículos, RX 580 8 GB Vulkan)

- **Itália (37 min, `beamng.2.log`):** **16 limpezas automáticas sem falhas**, recuperando **1.972–2.147 MB por limpeza** e **0** erros `Failed to wait for fences`.
- **West Coast USA com perseguição policial (17 min, `beamng.1.log`):** **9/9 limpezas no 1º pulso (`206–285 ms`)**, recuperando **18.528 MB (~18,5 GB)** sob pressão de `~120 MB/s` em perseguição, com piso estável em `4.040 MB` e **0** erros de fence ou `VK_ERROR_DEVICE_LOST`.
- **Verificação da limpeza assistida por SWAP (logs `v1.2.x` em West Coast USA):** limpezas em 1 pulso disparadas em `78%–80%` de VMA com `SWAP >= 1.032 MB` recuperaram consistentemente **`1.520–1.796 MB` de VRAM** em um único pulso (`~290–305 ms`).

---

## Como Instalar

### Opção 1 — Instalação Fácil (Recomendada)
1. Baixe o arquivo `beamng_vulkan_vram_fix.zip` na aba [**Releases**](https://github.com/arthurquadro/beamng-vulkan-vram-fix/releases/latest).
2. Coloque o `.zip` (sem extrair) na pasta de mods do BeamNG:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
   ```
   *(Normalmente `C:\Users\<SeuUsuario>\AppData\Local\BeamNG\BeamNG.drive\current\mods\`.)*
3. Certifique-se de que o mod esteja **Ativo** no Gerenciador de Mods do jogo (ou veja a Opção 3 abaixo caso use "Desativar Todos os Mods").
4. Abra o **BeamNG.drive** no modo **Vulkan**.

### Opção 2 — Instalação Descompactada (Código-Fonte)
1. Baixe ou clone este repositório.
2. Copie as pastas `scripts/` e `lua/` para:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamng_vulkan_vram_fix\
   ```
3. Abra o **BeamNG.drive** no modo **Vulkan**.

### Opção 3 — Instalação Persistente à Prova de Desativação (Opcional)
Como `core_modmanager.initDB()` varre `/scripts/*/modScript.lua` direto na raiz da pasta de usuário mesmo se todos os mods estiverem desativados:
1. Extraia `lua/ge/extensions/vulkanVramFix.lua` e `scripts/beamng_vulkan_vram_fix/modScript.lua` diretamente em:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\
   ```
2. Assim a proteção continua ativa mesmo se você clicar em **"Desativar Todos os Mods"** (sem alterar nenhum arquivo original da Steam).

---

## Comandos no Console do Jogo (Opcional)

Abra o console (`~` ou `'`), selecione o modo **BeamNG - Lua / GE** e use:

| Comando | Função |
| :--- | :--- |
| `vulkanVramFix.status()` | Mostra versão, % do orçamento VMA, VRAM física, uso de SWAP não-local, `$gfx::transientPoolBudgetMB`, total de limpezas, MB recuperados e status do streaming de texturas. |
| `vulkanVramFix.flushNow()` | Executa uma limpeza imediata dos pools Vulkan na hora. |
| `vulkanVramFix.setBudgetMB(384)` | Ajusta o `$gfx::transientPoolBudgetMB` (`128`–`2048` MB; padrão `384`). Útil em placas com 12 GB+ de VRAM. |
| `vulkanVramFix.setAutoFlush(false)` | Desativa temporariamente a limpeza automática (`true` para reativar). |

---

## Opcional: Parâmetros de Inicialização na Steam (Windows)

Várias camadas implícitas de terceiros no Vulkan (OBS, Steam Overlay, Steam Fossilize, Epic Online Services, RTSS, AMD Switchable Graphics) podem empilhar sobre o driver e piorar a estabilidade. Você pode desativá-las apenas para o BeamNG em **Steam → BeamNG.drive → Propriedades → Opções de Inicialização** (sem espaço antes de `&`):

```cmd
cmd /c "set DISABLE_VULKAN_OBS_CAPTURE=1& set EOS_OVERLAY_DISABLE_VULKAN_WIN64=1& set DISABLE_VK_LAYER_VALVE_steam_overlay_1=1& set DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1& set DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1& set DISABLE_RTSS_LAYER=1& %command% -gfx vk"
```

- Remova `set DISABLE_RTSS_LAYER=1&` se quiser manter o overlay do MSI Afterburner / RivaTuner visível na tela.
- `DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1` só tem efeito em placas AMD e é ignorado com segurança em NVIDIA/Intel.

---

## Observações e Limitações Conhecidas

- A chamada a `Canvas:repaintUIThrottled()` pode causar uma piscada bem rápida (~1 frame) no instante em que uma limpeza de VRAM ou SWAP é executada.
- Pela especificação do Vulkan, quando um buffer ou textura já foi alocado na RAM via PCIe (`SWAP`), ele não pode ser migrado de volta para a VRAM sem recarregar. A `v1.2.1` mantém folga na VRAM abaixo dos limiares de despejo sem interromper o tráfego ativo de staging no `SWAP` quando a VRAM está baixa.
- Testado no **BeamNG.drive v0.40.6.0**. Atualizações futuras do jogo podem corrigir a limpeza dos pools Vulkan nativamente na engine.

---

## Licença

Licenciado sob a **MIT License** — veja [LICENSE](LICENSE).

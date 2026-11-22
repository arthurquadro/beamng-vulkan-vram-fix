# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇺🇸 **English version:** [README.md](README.md)

Um mod leve e não-destrutivo (`v1.2.0`) para **BeamNG.drive** que impede o **estouro progressivo de VRAM no Vulkan** e o **transbordamento para a memória compartilhada/SWAP na RAM do sistema (`nonLocalUsageBytes`)** — evitando o gargalo que derruba o FPS para ~10–14 FPS ou causa crashes `VK_ERROR_DEVICE_LOST` (quando só mudar uma opção gráfica fazia a VRAM cair temporariamente).

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

## Novidades da `v1.2.0` (Proteção Anti-SWAP / Memória GPU Não-Local)

Uma nova etapa de engenharia reversa no binário explicou por que em mapas pesados (como **West Coast USA**) o FPS ainda podia despencar para ~14 FPS com ~2,2 GB aparentemente livres na VRAM enquanto o contador de **SWAP / Memória Compartilhada** passava de 2+ GB:

1. **`Engine.Render.getMemoryInfo()` (`0x140EFBA40`) é cego ao `SWAP`:** a função lê apenas heaps `VK_MEMORY_HEAP_DEVICE_LOCAL_BIT` e fixa `sharedBytes = 0` em GPUs dedicadas (`0x140EFBBFA`). Já **`Engine.Platform.getGPUAdaptersInfo()`** (`0x140EFA680` → `0x140EF7C90`) consulta `VK_EXT_memory_budget` diretamente e expõe **`nonLocalUsageBytes` / `nonLocalBudgetBytes`** (`SWAP`). Além disso, em `0x140F0EEA3`, o próprio C++ `checkVmaHeapBudgets` autoriza limpeza imediata no 1º pulso sempre que `nonLocalUsageBytes >= 1 GiB`.
2. **Callback OOM quebrado e fallback irreversível para o `SWAP`:** `vku::GenericBuffer` (`0x140EE42DD`) e `vku::GenericImage::create` (`0x14037E22C`) apontam o callback de falta de memória do VMA (`[0x142FC66F8]`, `0x140F0E415`) para uma função vazia (`0x1401035E0 = ret 0`). Quando a VRAM chega perto do orçamento ou fragmenta, o alocador desativa `DEVICE_LOCAL` e joga malhas/texturas do mapa direto no `Heap 2` (RAM via PCIe, ~15–20× mais lenta), de onde o Vulkan nunca mais consegue movê-las de volta.
3. **Prioridades invertidas no `VK_EXT_memory_priority` + `VK_EXT_pageable_device_local_memory`:** render targets e buffers temporários de luz/sombra (incluindo `1–2 GB` parados nos pools) recebem `priority = 1.0f` (`0x14037E100` / `0x140EE417C`), enquanto a geometria e texturas vivas do mapa recebem `priority = 0.75f`. Quando o WDDM do Windows encolhe dinamicamente o orçamento (ex.: de `7.368 MB` para `6.879 MB`), o driver expulsa justamente o mapa (`0.75f`) para o `SWAP` para proteger o lixo acumulado (`1.0f`).
4. **O que a `v1.2.0` faz para corrigir:**
   - **Monitora o `SWAP` (`nonLocalUsageBytes`) em tempo real** via `Engine.Platform.getGPUAdaptersInfo()`, zerando backoffs quando o SWAP cai.
   - **Mantém folga preventiva na VRAM:** reduz `$gfx::transientPoolBudgetMB` para **`256 MB`**, reduz a limpeza em pausa para **`64%`**, cria **guarda de contração do WDDM** (`≥ 78%` quando `budgetMB < 87%` da VRAM física), cria **guarda de crescimento do SWAP** (`≥ 640 MB` ou pressão combinada `≥ 86%`) e aciona **limpeza no 1º pulso a partir de `1032 MB` de `SWAP`** (`0x140F0EEA3`).
   - **Limpeza pós-carregamento e pós-ajuste gráfico:** limpa listas de staging acumuladas após `10 s` do fim do spawn de mapa/tráfego e `2 s` após alterações de configurações gráficas.

### Marco Anterior (`v1.1.0` — Alinhamento com Orçamento VMA)

- O disassembly de `GFXVkDevice::getMemoryInfo` (`0x140EFBA40`) mostrou que `availableBytes = max(0, budgetBytes - usageBytes)` em vez de `dedicatedBytes - usageBytes`. Disparamos em `usageBytes / budgetBytes >= 0.852` garantindo limpezas no **1º pulso** em `~198–260 ms` (`16/16` em Itália e `9/9` em perseguições de West Coast USA recuperando `18,5 GB` com `0` erros de fence).

---

## O que Este Mod Faz

1. **Reduz `$gfx::transientPoolBudgetMB` de `1536 MB` para `256 MB`** no Vulkan (reaplicado automaticamente ao iniciar mapa ou alterar gráficos, sem mexer em nenhuma opção visual do jogador).
2. **Monitora VRAM e `SWAP` (memória GPU não-local)** via `Engine.Render.getMemoryInfo()` e `Engine.Platform.getGPUAdaptersInfo()`, chamando `Canvas:repaintUIThrottled()` com segurança fora do passe de renderização (`onUpdate`):
   - **Pressão de VMA (`≥ 85,2%` de `budgetBytes`)** ou **teto de `SWAP` (`≥ 1032 MB`)**: aciona `checkVmaHeapBudgets` no **1º pulso (~200–260 ms)**.
   - **Contração de orçamento do WDDM (`≥ 78%` com orçamento `< 87%` da VRAM física)** e **crescimento de `SWAP` (`≥ 640 MB`, +160 MB sobre o piso)**: executa preventivamente o ciclo de 5 pulsos (`~250 ms`) antes que o Windows expulse o mapa para a RAM via PCIe.
   - **Em pausa:** faz limpeza oportunista a partir de **`≥ 64%` do orçamento VMA** ou **`SWAP ≥ 512 MB`** (+128 MB sobre o piso).
   - **Pós-carregamento e pós-configurações:** esvazia buffers de staging residuais `10 s` após terminar de carregar o mapa/tráfego e `2 s` após mudanças de qualidade gráfica.
   - **Proteção anti-loop e piso de SWAP:** se a memória estiver legitimamente ocupada por assets estáticos (`< 192 MB` VRAM e `< 128 MB` SWAP liberados), aumenta o intervalo automaticamente (`25 s → 90 s` VRAM, `30 s → 120 s` SWAP) e recalibra o piso do SWAP.

### Telemetria Comprovada (`beamng.2.log` e `beamng.1.log` — Citybus + 7 Veículos, RX 580 8 GB Vulkan)

- **Itália (37 min, `beamng.2.log`):** **16 limpezas automáticas sem falhas**, recuperando **1.972–2.147 MB por limpeza** e **0** erros `Failed to wait for fences`.
- **West Coast USA com perseguição policial (17 min, `beamng.1.log`):** **9/9 limpezas no 1º pulso (`206–285 ms`)**, recuperando **18.528 MB (~18,5 GB)** sob pressão de `~120 MB/s` em perseguição, com piso estável em `4.040 MB` e **0** erros de fence ou `VK_ERROR_DEVICE_LOST`.

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
| `vulkanVramFix.setBudgetMB(256)` | Ajusta o `$gfx::transientPoolBudgetMB` (`128`–`2048` MB; padrão `256`). Útil em placas com 12 GB+ de VRAM. |
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
- Pela especificação do Vulkan, quando um buffer ou textura já foi alocado na RAM via PCIe (`SWAP`), ele não pode ser migrado de volta para a VRAM sem recarregar. A `v1.2.0` atua preventivamente mantendo folga na VRAM e limpando slabs de staging/voláteis antes que o WDDM empurre partes do mapa para o `SWAP`.
- Testado no **BeamNG.drive v0.40.6.0**. Atualizações futuras do jogo podem corrigir a limpeza dos pools Vulkan nativamente na engine.

---

## Licença

Licenciado sob a **MIT License** — veja [LICENSE](LICENSE).

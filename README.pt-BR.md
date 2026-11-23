# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇺🇸 **English version:** [README.md](README.md)

Um mod leve e não-destrutivo (`v1.3.1`) para **BeamNG.drive** que impede o **estouro progressivo de VRAM no Vulkan** e o **transbordamento sob alta VRAM para o "SWAP" na RAM do sistema (`nonLocalUsageBytes`)** — evitando quedas para ~10–14 FPS ou crashes, enquanto agenda as limpezas em janelas invisíveis ou de baixa movimentação para minimizar stutters.

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

## Novidades da `v1.3.1` (Refinamentos da Auditoria Forense & Blindagem de Borda)

Evoluindo o agendador suave em 4 camadas da `v1.3.0`, a `v1.3.1` blinda detecção de menus, recalibração de piso de VRAM, proteção de transferências na GPU e eficiência no LuaJIT:

1. **Whitelist explícita de menus (`ui_router` + exclusão de Modo Foto / World Editor):** substitui `routeName ~= "play"` por uma whitelist explícita (`"menu"`, `"menu.*"`, `"pause"`, `"pause.*"`, `"scenario.end"`, `"scenario.*.end"`), excluindo explicitamente Modo Foto (`pause.photomode`), Espelhos no Radial (`radial.mirrors`) e o World Editor (`F11`). Rotas de condução como Táxi (`"taxi"`), Track Builder (`"trackBuilder"`) e Split-Screen não disparam mais limpeza de menu durante a direção.
2. **Menu Radial sem pausa restrito a 1 único pulso:** o Menu Radial semitransparente (`core_quickAccess`) agora só dispara quando há garantia de **1 pulso** (`SWAP >= 1032 MB` ou `VMA >= 85,2%`), eliminando 5 piscadas sobre a câmera 3D viva.
3. **Recalibração bidirecional de `vramFloorMB`:** ajusta o piso tanto para cima quanto para baixo sempre que `waitIdleAndFreeResources()` realmente executar (`>= 15 ms`), acompanhando a adição e remoção de tráfego/polícia sem acumular falsos positivos.
4. **Detecção do throttle silencioso de `33,3 ms` com 1 retry automático:** se `GuiCanvas::repaintUIThrottled()` (`0x140446383`) retornar em `< 8 ms` por bloqueio do gate C++ de `1/30 s`, agenda **1 retry após `60 ms`** em vez de perder o pulso e entrar em backoff à toa.
5. **Confirmação em 2 amostras parado & carência de `3 s` pós-spawn:** exige `>= 2` amostras consecutivas imóvel (`>= 1 s`) para `stopped_opportunistic` e cria uma janela de `3,0 s` em `onVehicleSpawned` impedindo limpezas oportunistas enquanto o `transferAcc` sobe as malhas/texturas do carro novo.
6. **Ciclo de vida limpo & borda de subida de `SWAP`:** adiciona `onClientEndMission`, cancela verificações em loading/mudança gráfica, zera consultas pesadas no Alt-Tab, força leitura imediata de `SWAP` na borda de subida de `68%` VMA, elimina todas as closures anônimas em `pcall` para o LuaJIT e protege o [modScript.lua](scripts/beamng_vulkan_vram_fix/modScript.lua) com `pcall`.

### Marcos Anteriores (`v1.3.0`, `v1.2.1`, `v1.2.0` e `v1.1.0`)

- **`v1.3.0` (Limpeza Oportunista Suave):** introduziu consulta preguiçosa de `SWAP` (`>= 68%` VMA, intervalo de 4 s), verificação pós-limpeza adiada (`0,50 s` + `>= 12` quadros), calibração de `vramFloorMB` e agendamento em 4 camadas (menus/pausa invisíveis, resets/trocas de veículo, paradas no trânsito e adiamento suave de `78,0% → 83,5%` por até `20 s`).
- **`v1.2.1` (Hotfix `VK_ERROR_DEVICE_LOST`):** corrigiu o loop de `swap_pressure` sob VRAM baixa da `v1.2.0` exigindo VRAM elevada (`≥ 78%`), validação estrita apenas por VRAM (`≥ 192 MB`), 1 pulso quando `VMA ≥ 85,2%` ou `SWAP ≥ 1032 MB`, cooldowns de `15 s` e restauração de `$gfx::transientPoolBudgetMB = 384 MB`. Verificada em West Coast USA (`beamng.log` da `v1.2.1`: 4/4 limpezas limpas em 1 pulso recuperando `1.340–1.615 MB` cada, `0` crashes).
- **`v1.2.0` (Visibilidade de `SWAP`):** expôs `nonLocalUsageBytes` via `Engine.Platform.getGPUAdaptersInfo()` (`0x140EFA680`), aproveitando o corte de `1 GiB` em 1 pulso do C++ (`0x140F0EEA3`) para evitar despejo da geometria do mapa (`priority = 0.75f`) na RAM via PCIe (`Heap 2`).
- **`v1.1.0` (Alinhamento com Orçamento VMA):** alinhou o gatilho ativo a `usageBytes / budgetBytes >= 0.852`, casando exatamente com `GFXVkDevice::getMemoryInfo` (`0x140EFBA40`) e `checkVmaHeapBudgets(0.85f)` (`0x140F0ED80`).

---

## O que Este Mod Faz

1. **Reduz `$gfx::transientPoolBudgetMB` de `1536 MB` para `384 MB`** no Vulkan (reaplicado automaticamente ao iniciar mapa ou alterar gráficos, sem mexer em nenhuma opção visual do jogador).
2. **Monitora a VRAM sem alocar closures no LuaJIT (e consulta `SWAP` apenas quando `VMA ≥ 68%` e com foco)**, chamando `Canvas:repaintUIThrottled()` com segurança fora do passe de renderização (`onUpdate`) em 4 camadas:
   - **Menus / pausa / BigMap (e Menu Radial em 1 pulso):** limpa silenciosamente a partir de **`≥ 64%` VMA** (`+550 MB` acima do piso recalibrado), excluindo Modo Foto e World Editor.
   - **Reset / troca de veículo e paradas:** aguarda `3 s` após qualquer spawn (`onVehicleSpawned`) e esconde limpezas em 1 pulso em resets (`≥ 68%`) ou paradas confirmadas em 2 amostras (`≥ 72%`, `≤ 2,9 km/h` por `≥ 1 s`).
   - **Dirigindo em velocidade:** adia suavemente entre **`78,0% → 83,5%`** (com `SWAP ≥ 1032 MB`) por até `20 s` esperando desaceleração, corte de câmera ou menu, mantendo tetos seguros em **1 pulso** (com 1 retry automático de `60 ms` caso bloqueado pelo gate de `33,3 ms`) aos **`83,5%`** (com `SWAP ≥ 1032 MB`) ou **`85,2%`** VMA.
   - **Cooldowns de segurança e proteção anti-loop:** impõe intervalo mínimo de **`15 s`** após limpezas (**`15 s`** pós-mapa e **`5 s`** pós-gráficos / saída ao menu) e adia a leitura pós-limpeza por `0,50 s` (`≥ 12` quadros); se recuperar `< 192 MB` de VRAM, recua (`30 s → 90 s`).

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
- Pela especificação do Vulkan, quando um buffer ou textura já foi alocado na RAM via PCIe (`SWAP`), ele não pode ser migrado de volta para a VRAM sem recarregar. A `v1.3.1` mantém folga segura na VRAM enquanto esconde as limpezas dentro de menus, resets e paradas verificadas sempre que possível.
- Testado no **BeamNG.drive v0.40.6.0**. Atualizações futuras do jogo podem corrigir a limpeza dos pools Vulkan nativamente na engine.

---

## Licença

Licenciado sob a **MIT License** — veja [LICENSE](LICENSE).

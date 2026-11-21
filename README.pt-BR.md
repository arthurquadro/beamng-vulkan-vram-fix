# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇺🇸 **English version:** [README.md](README.md)

Um mod leve e não-destrutivo para **BeamNG.drive** que impede o **estouro progressivo de VRAM no Vulkan** — quando a VRAM sobe continuamente (de ~100 em ~100 MB) com **qualquer veículo** até lotar a placa, derrubar o FPS ou travar com `VK_ERROR_DEVICE_LOST` (e só cai de volta quando você muda alguma opção gráfica).

- **Funciona com qualquer veículo e qualquer mapa** — não altera nenhum arquivo de veículo nem do jogo.
- **Funciona em placas AMD, NVIDIA e Intel** (atua apenas no Vulkan; fica inativo automaticamente no DirectX 11 / DirectX 12).
- **100% Lua puro (apenas 2 arquivos pequenos)** — zero conflito com outros mods.
- **Preserva todas as suas configurações gráficas** — você pode mudar gráficos, resolução, Profundidade de Campo (DoF) e espelhos livremente no menu sem quebrar a correção.

---

## Por que Esse Problema Acontece (Causa Raiz)

A análise técnica do executável `BeamNG.drive.x64.exe` (`v0.40.6.0`) revelou por que a VRAM sobe continuamente no Vulkan (enquanto no DirectX 12 fica estável) e por que mudar qualquer opção gráfica fazia a VRAM cair na hora:

1. **Pools internos do Vulkan não são limpos durante a gameplay:** o método `GFXVkDevice::endScene` nunca apara a lista de slabs de transferência de `16 MB` (`"Buffer volatile cpu"`) e retém até `32 × 8 MB` de slabs dinâmicos por bucket na VRAM, além de outros caches internos. Quando você muda uma opção gráfica, o jogo chama `GFXVkWindowTarget::resetModeInternal` → `GFXVkDevice::waitIdle()`, limpando tudo de uma vez.
2. **Coletor automático de VRAM órfão:** o próprio motor do BeamNG já possui uma função de limpeza sob pressão de VRAM (`GFXVkDevice::vtable[+0x108]`) que dispara `waitIdle()` quando a VRAM passa de 85% ou a memória GPU compartilhada passa de 1 GB. Porém, o **único chamador** dela no binário é `GuiCanvas::repaintUIThrottled()`, que o Lua original só chama durante a **tela de carregamento** (`updateLoadingProgress`), nunca durante a gameplay normal.
3. **Orçamento padrão exagerado do `transientPool`:** a variável interna `$gfx::transientPoolBudgetMB` vem em **`1536 MB`** (1,5 GB), segurando render targets ociosos — algo especialmente pesado em placas de 8 GB sem Resizable BAR (BAR de 256 MB).

---

## O que Este Mod Faz

1. **Reduz `$gfx::transientPoolBudgetMB` de `1536 MB` para `384 MB`** no Vulkan (reaplicado automaticamente ao iniciar mapa ou alterar gráficos, sem mexer em nenhuma opção visual do jogador).
2. **Reativa o coletor de memória Vulkan do próprio jogo durante a gameplay:** monitora `Engine.Render.getMemoryInfo()` uma vez por segundo (custo de CPU praticamente nulo):
   - **Em gameplay ativo:** ao atingir **≥ 78% de VRAM** (ou **≤ 1,60 GiB livres**), chama `Canvas:repaintUIThrottled()` com segurança fora do passe de renderização (`onUpdate`), esvaziando os pools acumulados **antes** que a VRAM lote e derrube o FPS.
   - **Em pausa:** faz limpeza oportunista a partir de **≥ 65% de VRAM** enquanto o menu de pausa está aberto.
   - **Proteção anti-loop:** se uma limpeza recuperar menos de `192 MB` (indicando que a VRAM está legitimamente ocupada por texturas estáticas da cena), aumenta automaticamente o intervalo de espera (`25 s → 60 s`).

### Resultados Reais Comprovados (`beamng.log` — RX 580 8 GB, Vulkan)

Todas as limpezas funcionaram **no primeiro pulso (~280 ms)**, mantendo a VRAM estável entre **4,6 GB e 6,4 GB** em vez de bater 8 GB e cair para 10 FPS:

```text
Set $gfx::transientPoolBudgetMB = 384 MB (was 1536)
Triggering Vulkan pool flush (vram_pressure): VRAM 6479 / 8192 MB (79.1%, free 1.67 GiB)
Vulkan pool flush succeeded after 1 tap(s): reclaimed 1872 MB (now 4608 / 8192 MB)
Triggering Vulkan pool flush (vram_pressure): VRAM 6441 / 8192 MB (78.6%, free 1.71 GiB)
Vulkan pool flush succeeded after 1 tap(s): reclaimed 1817 MB (now 4624 / 8192 MB)
Triggering Vulkan pool flush (paused_opportunistic): VRAM 5478 / 8192 MB (66.9%, free 2.65 GiB)
Vulkan pool flush succeeded after 1 tap(s): reclaimed 607 MB (now 4871 / 8192 MB)
```

---

## Como Instalar

### Opção 1 — Instalação Fácil (Recomendada)
1. Baixe o arquivo `beamng_vulkan_vram_fix.zip` na aba [**Releases**](https://github.com/arthurquadro/beamng-vulkan-vram-fix/releases/latest).
2. Coloque o `.zip` (sem extrair) na pasta de mods do BeamNG:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
   ```
   *(Normalmente `C:\Users\<SeuUsuario>\AppData\Local\BeamNG\BeamNG.drive\current\mods\`.)*
3. Abra o **BeamNG.drive** no modo **Vulkan**.

### Opção 2 — Instalação Descompactada (Código-Fonte)
1. Baixe ou clone este repositório.
2. Copie as pastas `scripts/` e `lua/` para:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamng_vulkan_vram_fix\
   ```
3. Abra o **BeamNG.drive** no modo **Vulkan**.

---

## Comandos no Console do Jogo (Opcional)

Abra o console (`~` ou `'`), selecione o modo **BeamNG - Lua / GE** e use:

| Comando | Função |
| :--- | :--- |
| `vulkanVramFix.status()` | Mostra VRAM atual, `$gfx::transientPoolBudgetMB`, total de limpezas e MB recuperados. |
| `vulkanVramFix.flushNow()` | Executa uma limpeza imediata dos pools Vulkan na hora. |
| `vulkanVramFix.setBudgetMB(512)` | Ajusta o `$gfx::transientPoolBudgetMB` (`128`–`2048` MB). Útil em placas com 12 GB+ de VRAM. |
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

- Quando a VRAM atinge o limite de 78% em gameplay, a chamada a `Canvas:repaintUIThrottled()` pode causar uma piscada bem rápida (~1 frame) no instante da limpeza.
- Testado no **BeamNG.drive v0.40.6.0**. Atualizações futuras do jogo podem corrigir a limpeza dos pools Vulkan nativamente na engine.

---

## Licença

Licenciado sob a **MIT License** — veja [LICENSE](LICENSE).

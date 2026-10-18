# M3 Desk 0.2.3

Aplicativo nativo macOS para retomar um projeto, consultar contexto autorizado, preparar um handoff e acompanhar execuções. Esta versão mantém a identidade do bundle `local.m3desk.mvp` e os rascunhos anteriores.

## Executar e verificar

Requer macOS 14 ou posterior e Swift 6. A verificação desta entrega usou o Command Line Tools instalado, sem instalar outro toolchain.

```sh
swift run --build-system swiftbuild M3Desk
./scripts/verify.sh
```

O script de verificação habilita o plugin Swift Testing disponível no toolchain e executa testes e smoke local. Para evitar lentidão do provedor de arquivos em Documents, é possível copiar os fontes para uma pasta temporária e definir `M3_DESK_BUILD_DIR` fora de Documents. Não copie credenciais para essa pasta.

Para empacotar um executável já compilado:

```sh
./scripts/package-app.sh /caminho/do/executavel/M3Desk /tmp/M3Desk.app
```

A assinatura gerada é ad hoc; não é distribuição notarizada pela Apple.

## Uso

- Selecione organização, projeto e subprojeto na lateral. O filtro de projetos não muda a seleção atual. Busca na memória é um campo separado.
- O workspace mostra rascunho local, checkpoint remoto, mudanças, bloqueios e próxima ação. Adotar um checkpoint exige uma ação explícita.
- Handoff permite salvar, revisar, copiar e exportar Markdown. Copiar/exportar não envia mensagens a outra pessoa ou chat.
- Em Execuções, escolha explicitamente um executor anunciado, revise o objetivo exato e inicie. A escolha é salva no rascunho deste contexto. Acompanhe resultado textual, eventos e estado confirmado pelo servidor; cancele ou retome quando permitido.
- O contrato atual de criação envia apenas o objetivo e o provider escolhido. `local` é uma ferramenta Docker fixa; `local-model` é um modelo textual local experimental quando anunciado pelo servidor. O handoff completo continua disponível para cópia/exportação; ele não é enviado como contexto do run.

## Conexões

O MCP legado em `http://127.0.0.1:18080/mcp` é usado para descoberta de capacidades. Seu armazenamento compartilhado não concede isolamento por projeto; por isso a conexão MCP sozinha não habilita busca por projeto ou execução.

Configure uma API `m3.platform.v1` em Conexão. Use HTTPS ou loopback local. A credencial é guardada no Keychain; somente a URL e a escolha de conexão vão para UserDefaults. O registry da API define os projetos e as permissões disponíveis. Não há fallback automático da API para memória legada.

A capability `agent_execution` é distinta de registro de runs e não reclassifica execuções antigas. A lista `execution_providers` e os flags correspondentes habilitam as opções. O provider gravado em cada run determina seu rótulo; respostas do modelo são exibidas como texto, nunca executadas. O ambiente local anuncia Qwen2.5 0.5B experimental, sem ferramentas ou histórico entre pedidos. O resultado sintético comprova integração, não qualidade de produção ou aborto imediato do motor.

## Persistência e recuperação

Rascunhos, seleção, cursores e chaves de idempotência são locais. O namespace contém origem da API, principal, tenant, projeto e, para rascunhos, subprojeto. Rascunhos legados são migrados apenas no contexto local compatível; originais e casos ambíguos são preservados. O painel de recuperação permite escolher explicitamente um destino local vazio.

Resultados remotos ficam apenas na sessão e são limpos quando muda o contexto, a autorização falha, a conexão cai ou o prazo local de validação expira. Ao reconectar, a API é consultada novamente. Não há snapshot remoto offline persistido. Uma cópia explicitamente adotada passa a compor o rascunho local.

Mutações sem resposta confirmada mantêm uma chave persistida. Repetir o mesmo objetivo com o mesmo provider, ou a mesma retomada, reutiliza essa chave. O mesmo objetivo com outro provider é uma operação distinta. A reconexão automática tem até três tentativas espaçadas e não reenvia mutações automaticamente.

## Validação isolada

Para revisar o app contra um backend de teste sem alterar o perfil normal:

```sh
M3Desk --verification-profile /caminho/absoluto/perfil \
  --platform-endpoint http://127.0.0.1:PORTA \
  --credential-file /caminho/privado/desk-client.json
```

O arquivo deve conter `base_url` e `token`; a URL deve corresponder ao argumento. O token é lido no processo, nunca colocado nos argumentos ou logs. O perfil mostra uma faixa de verificação e usa cache separado por origem.

O smoke remoto é opt-in:

```sh
M3_PLATFORM_SMOKE_ENDPOINT=http://127.0.0.1:PORTA \
M3_PLATFORM_SMOKE_TOKEN_FILE=/caminho/privado/desk-client.json \
M3DeskSmoke --live-platform --exercise-fixture-runs --exercise-local-model
```

`--exercise-fixture-runs` cria, cancela e retoma runs sintéticos de ferramenta; `--exercise-local-model` envia o objetivo fixo `Reply with exactly ACK.` ao provider anunciado `local-model`, espera a conclusão e verifica resultado/eventos/reconexão; use somente um ambiente autorizado para isso. `M3DeskSmoke --live-mcp` realiza o handshake e a descoberta do MCP real, sem ler conteúdo pessoal.

Detalhes de escopo e provenance: [docs/INTEGRATION.md](docs/INTEGRATION.md).

Para investigar uma falha do ensaio sem criar outro run, acrescente `--resume-local-model-run UUID` a `--live-platform --exercise-local-model`. Isso solicita explicitamente a retomada do mesmo run de teste, mantendo provider e objetivo e reutilizando a chave de retomada no replay. Preserve o log da primeira falha. O Desk mostra o código seguro de erro retornado pelo servidor, como `provider_timeout`; não altera limites do motor.

Quando o servidor informa `effect_requires_reconciliation`, o Desk exibe o motivo e bloqueia nova retomada até que o backend reconcilie o efeito. O app não cria outro run para contornar esse estado.

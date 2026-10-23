# Backup MySQL do INAT EAD

O serviço `mysql-backup` faz parte do Compose padrão e acessa `mysql:3306` pela
rede interna. A imagem contém Bash, cron, gzip, flock e os clientes Oracle
MySQL 8.0; não executa outro servidor MySQL nem publica portas.

**Todas as configurações ficam no mesmo `.env` da aplicação.** O Compose passa
somente as variáveis necessárias ao container. Não há `backup.conf`,
`client.cnf`, `restore.cnf` ou diretório de configuração separado para manter.
O `.env` não é copiado para a imagem nem executado com `source`.

Veja [VALIDATION.md](VALIDATION.md) para o registro da validação em ambiente
MySQL descartável e o estado da publicação/deploy.

## Configurar no .env

Os valores já usados pelo projeto são reutilizados:

- `DB_NAME`: banco operacional que será exportado e bloqueado como destino de restauração.
- `DB_USERNAME` e `DB_PASSWORD`: credenciais padrão do backup.
- `DB_ROOT_PASSWORD`: permanece sendo a senha administrativa do serviço MySQL;
  não é enviada ao container de backup por padrão.

As opções abaixo podem ser acrescentadas ao `.env`; todas são opcionais:

```dotenv
MYSQL_BACKUP_HOST=mysql
MYSQL_BACKUP_PORT=3306
MYSQL_BACKUP_HOST_DIR=/var/backups/inat/mysql
MYSQL_BACKUP_RETENTION_DAYS=30

# Preencha somente se quiser uma conta diferente da aplicação.
MYSQL_BACKUP_USERNAME=
MYSQL_BACKUP_PASSWORD=

# Vazios reutilizam host, porta, usuário e senha do backup.
MYSQL_RESTORE_HOST=
MYSQL_RESTORE_PORT=
MYSQL_RESTORE_USERNAME=
MYSQL_RESTORE_PASSWORD=
```

Os exemplos também estão no `.env.example` da raiz. Para valores contendo `$`
ou outros caracteres especiais, use aspas simples no `.env`, conforme o formato
aceito pelo Compose. Não coloque senhas nos argumentos de comandos.

Proteja o arquivo e mantenha-o fora do Git:

```bash
chmod 600 .env
```

O deploy restringe as permissões de grupo/outros do `.env` antes de usá-lo.
A senha dos clientes é fornecida pela variável `MYSQL_PWD`, somente na execução
do cliente; não aparece nos argumentos nem nos logs do script. Não ative
`set -x` nem grave a saída completa de `docker compose config` em logs.

A retenção tem padrão e mínimo de **30 dias**. São aceitos inteiros de 30 a
36500. Nomes de bancos aceitam até 64 letras, números ou underscores. A porta
precisa estar entre 1 e 65535. A configuração é validada pelo comando `check`.

## Permissões no MySQL

Com a conta padrão da aplicação, os grants existentes no banco operacional já
permitem ler tabelas e outros objetos. Para exportar definições de rotinas de
outros definers, conceda também `SHOW_ROUTINE` uma vez no MySQL 8.0.20+.
Abra o cliente administrativo no container do banco:

```bash
docker compose exec -e MYSQL_HISTFILE=/dev/null mysql mysql --user=root --password
```

No prompt MySQL, adapte o usuário ao `DB_USERNAME` real:

```sql
GRANT SHOW_ROUTINE ON *.* TO 'inat_ead'@'%';
```

Se preferir uma conta exclusiva, crie-a e preencha `MYSQL_BACKUP_USERNAME` e
`MYSQL_BACKUP_PASSWORD` no mesmo `.env`:

```sql
CREATE USER 'inat_backup'@'%' IDENTIFIED BY '<senha escolhida no servidor>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON `inat_ead`.* TO 'inat_backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'inat_backup'@'%';
```

A conta de dump não precisa de INSERT/UPDATE/DELETE. `--no-tablespaces` dispensa
`PROCESS`. Não se alteram credenciais, grants ou conexão da aplicação
automaticamente. A conta de restauração precisa de privilégios no destino,
conforme a seção de restauração.

## Deploy e agendamento

O CI executa o teste de integração antes da publicação. O workflow publica
`ghcr.io/inat-instituto-nacional-do-trabalhador/inat-mysql-backup` com tags `latest` e
`sha-<commit>`, junto das imagens de backend e frontend. O release fixa as três
imagens no mesmo commit. No servidor, o deploy baixa as imagens, executa
`mysql-backup check` e inicia o Compose com `--no-build --wait`.

Não é necessário copiar scripts ou instalar cron/clientes MySQL no host.
Com o `.env` preenchido e o usuário do banco autorizado, o serviço inicia com o
Compose padrão. Para atualizar apenas o backup manualmente, após a publicação:

```bash
docker compose pull mysql-backup
docker compose run --rm --no-deps mysql-backup check
docker compose up --detach --no-deps --no-build --wait mysql-backup
```

Para desenvolvimento local, `docker compose build mysql-backup` constrói a
imagem sem publicá-la. Após alterar configurações no `.env`, recrie o container
para que o cron use os novos valores:

```bash
docker compose up --detach --no-deps --force-recreate mysql-backup
```

O cron agenda **02h15 diariamente, no fuso do host**, montando `/etc/localtime`
somente para leitura. Ele recupera automaticamente as variáveis originais do
container; não exige um arquivo adicional de configuração. O nome dos backups
e os horários dos logs usam **UTC**, com sufixo `Z`.

Confira a agenda, o fuso e a saúde do serviço:

```bash
docker compose ps mysql-backup
docker compose exec mysql-backup date '+%Y-%m-%d %H:%M:%S %Z %z'
docker compose exec mysql-backup cat /etc/cron.d/mysql-backup
```

O healthcheck confirma que cron está vivo; o sucesso do backup deve ser
conferido nos logs e nos artefatos. Cron não repõe automaticamente execuções
perdidas enquanto o host/container estava parado. Nesse caso execute um backup
manual. Após mudar o fuso do host, recrie o serviço para atualizar o mount e o
estado do cron.

## Armazenamento, logs e backup manual

O diretório padrão é **`/var/backups/inat/mysql` no host**, montado em `/backups`.
O Docker cria o diretório pelo bind mount e o container aplica modo `0700`.
Cada backup tem modo `0600` e nome como:

```text
inat_ead_20261022T051500Z_aB12cD34.sql.gz
```

Mude `MYSQL_BACKUP_HOST_DIR` no `.env` para escolher outro diretório no host.
Em hosts com SELinux enforcing, prepare o rótulo desse diretório conforme a
política local. Não aplique relabel ao `/etc/localtime` do host.

**Não há cópia externa configurada.** O bind mount mantém os arquivos após
remover o container, mas depende do disco desse host. Uma cópia para outro host
ou armazenamento de objetos precisa ser configurada separadamente e copiar
somente arquivos finalizados, nunca `.partial`. O volume `file_storage` do
backend também precisa de backup próprio para recuperar os anexos do portal.

```bash
docker compose run --rm --no-deps mysql-backup backup
docker compose logs --since 48h mysql-backup
docker compose logs --follow mysql-backup
sudo ls -lh /var/backups/inat/mysql
```

O dump inclui estrutura, dados, views, procedures, funções, eventos e triggers.
Usa `--single-transaction --quick --routines --events --triggers --hex-blob`,
`--no-tablespaces`, `--set-gtid-purged=OFF` e `--column-statistics=0`.
Não usa `--databases` ou `--all-databases`, nem exporta usuários, grants ou
binlogs. Não oferece recuperação ponto a ponto entre os backups diários.

`--single-transaction` dá consistência às tabelas InnoDB. Evite migrações/DDL
concorrentes; tabelas não transacionais e mudanças nas definições de rotinas
ou eventos exigem coordenação ou janela de manutenção.

Uma trava `flock` em `/backups/.mysql-backup.lock` impede backup e restauração
simultâneos; uma operação concorrente sai com código 75. Não apague o arquivo
de trava. O sistema libera a trava quando o processo sai.

O dump é compactado em `.sql.gz.partial`; `pipefail` detecta falhas na exportação
ou compactação. Somente depois de `gzip -t` o arquivo é renomeado no mesmo
diretório para `.sql.gz`. A retenção só começa após essa publicação bem-sucedida.
Ela remove apenas backups completos desse banco com mais de
`MYSQL_BACKUP_RETENTION_DAYS` dias pelo mtime, preservando arquivos recentes,
de outros bancos ou fora do padrão. Evite alterar o mtime ao copiar arquivos
para o diretório gerenciado.

Falhas antes da publicação preservam todos os backups completos existentes.
Falhas na retenção preservam o arquivo recém-publicado e são registradas.
Temporários são apagados na saída; SIGKILL/perda de energia podem deixar
`.partial`, removidos pela próxima execução que conseguir a trava.
Erros brutos dos clientes são descartados para não publicar SQL ou dados nos
logs. Confira conexão e grants ao investigar uma falha.

Os logs vão para stdout/stderr; o Docker mantém até três arquivos de 10 MB.
Execuções manuais escrevem no terminal. Monitore `[ERROR]`, espaço livre e a
ausência de um arquivo novo/`backup completed` por mais de um dia. Não há alerta
externo configurado. **`gzip -t` verifica a compactação; a prova de recuperação
é a restauração testada no MySQL descartável.**

## Restauração exclusivamente manual

O destino precisa estar criado e vazio. A restauração recusa o banco
operacional, bancos de sistema, nomes inválidos e destinos com tabelas, views,
rotinas, eventos ou triggers. Impeça outros clientes de escrever no destino
durante a operação; a trava do script não bloqueia clientes externos.

1. Crie o destino no MySQL com um administrador e autorize o usuário de
   restauração. Por padrão, esse usuário é o mesmo do backup. Se usar outra
   conta, preencha `MYSQL_RESTORE_USERNAME` e `MYSQL_RESTORE_PASSWORD` no `.env`;
   `MYSQL_RESTORE_HOST` e `MYSQL_RESTORE_PORT` permitem outro servidor acessível
   pela rede do Compose.

   ```sql
   CREATE DATABASE `inat_restore_validacao` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
   GRANT ALL PRIVILEGES ON `inat_restore_validacao`.* TO 'inat_ead'@'%';
   ```

   Substitua a conta pelo usuário real configurado. Dumps com outros `DEFINER`
   podem exigir `SET_USER_ID` no MySQL 8.0; funções com binlog habilitado podem
   precisar de privilégios adicionais ou de uma política adequada de
   `log_bin_trust_function_creators`. A ferramenta não modifica esses grants.
   O script recusa importar com `@@GLOBAL.event_scheduler=ON`, evitando execução
   de eventos antes da conferência. Se a produção depende de eventos ativos,
   use uma instância isolada com o scheduler desligado.

2. Escolha o arquivo completo e execute:

   ```bash
   docker compose run --rm --no-deps mysql-backup restore \
     /backups/inat_ead_20261022T051500Z_aB12cD34.sql.gz inat_restore_validacao
   ```

   `/backups` é o caminho visto dentro do container. O MySQL precisa estar
   rodando porque `--no-deps` não inicia dependências. O container temporário
   usa a rede e o bind mount do serviço e é removido ao encerrar; os artefatos
   permanecem no host.

   O arquivo passa por `gzip -t` e é descompactado por inteiro em um diretório
   privado de `/tmp` antes da importação. Reserve espaço para o SQL descompactado:
   `/tmp` usa tmpfs. Para dumps maiores, use um override com armazenamento
   temporário privado adequado e limpe-o após a operação.

   Use somente arquivos confiáveis produzidos por esta ferramenta. A validação
   recusa arquivos corrompidos, vazios, symlinks, `.partial`, origem diferente e
   instruções usuais de seleção/criação/exclusão de banco. Não é um sandbox de
   SQL: revise referências qualificadas e `DEFINER` em rotinas, views e eventos
   antes de executá-los.

   **Uma falha na importação pode deixar o destino parcialmente preenchido.**
   DDL causa commits implícitos: a operação inteira não é reversível como uma
   única transação. O cliente para no primeiro erro e os temporários são
   removidos, mas o destino não é apagado ou desfeito automaticamente. Inspecione
   a falha e use outro banco vazio antes de tentar novamente.

3. Confira os dados antes de qualquer troca de conexão. No MySQL do Compose,
   por exemplo, abra o cliente administrativo e faça consultas no destino:

   ```bash
   docker compose exec -e MYSQL_HISTFILE=/dev/null mysql mysql --user=root --password inat_restore_validacao
   ```

   ```sql
   SELECT DATABASE();
   SHOW FULL TABLES;
   SHOW TRIGGERS;
   SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE();
   SELECT EVENT_NAME, STATUS FROM information_schema.EVENTS WHERE EVENT_SCHEMA=DATABASE();
   -- Complete com contagens e amostras das tabelas de negócio esperadas.
   ```

   Para outro servidor, use um cliente apontando para o destino correspondente.
   **A ferramenta não altera a conexão da aplicação.** Essa decisão operacional
   fica para depois da conferência. Prefira uma instância isolada para executar
   rotinas/eventos restaurados que ainda não foram revisados.

## Testar em MySQL descartável

Na raiz do projeto, com Bash e acesso ao Docker:

```bash
bash docker/mysql-backup/tests/integration.sh
```

A suíte usa um projeto Compose aleatório, um `.env` temporário de modo `0600`,
credenciais geradas para o teste e MySQL 8.0 em tmpfs, sem portas publicadas.
Não lê o `.env` real nem monta `db_data`. Containers, rede, imagem de teste e
arquivos temporários são removidos ao terminar.

O teste confere restauração de dados UTF-8, tabelas, view, procedure, função,
evento e uma trigger executada de fato; retenção de 30 e 45 dias e mínimo de 30;
preservação dos backups após falhas; trava entre containers; destinos proibidos;
gzip corrompido; importação parcial; senhas com caracteres especiais e ausência
de credenciais nos logs; além de um job real de cron recuperando a configuração
do ambiente do container. A agenda do teste é de um minuto; a de produção é
conferida como 02h15. Essa etapa pode levar até 75 segundos.

Mensagens `PASS` e código de saída zero confirmam sucesso. Repita a suíte após
mudar scripts/imagens e faça exercícios periódicos com backups reais em um
ambiente isolado.

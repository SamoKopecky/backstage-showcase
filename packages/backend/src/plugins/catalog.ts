import { CatalogBuilder } from '@backstage/plugin-catalog-backend';
import {
  GithubEntityProvider,
  GithubOrgEntityProvider,
} from '@backstage/plugin-catalog-backend-module-github';
import { jsonSchemaRefPlaceholderResolver } from '@backstage/plugin-catalog-backend-module-openapi';
import { ScaffolderEntitiesProcessor } from '@backstage/plugin-scaffolder-backend';
import { GitlabFillerProcessor } from '@immobiliarelabs/backstage-plugin-gitlab-backend';
import { KeycloakOrgEntityProvider } from '@janus-idp/backstage-plugin-keycloak-backend';
import { ManagedClusterProvider } from '@janus-idp/backstage-plugin-ocm-backend';
import { Router } from 'express';
import { PluginEnvironment } from '../types';

export default async function createPlugin(
  env: PluginEnvironment,
): Promise<Router> {
  const builder = await CatalogBuilder.create(env);

  const isOcmEnabled = env.config.getOptionalBoolean('enabled.ocm') || false;
  const isKeycloakEnabled =
    env.config.getOptionalBoolean('enabled.keycloak') || false;
  const isGithubEnabled =
    env.config.getOptionalBoolean('enabled.github') || false;
  const isGithubOrgEnabled =
    env.config.getOptionalBoolean('enabled.githubOrg') || false;
  const isGitlabEnabled =
    env.config.getOptionalBoolean('enabled.gitlab') || false;

  const ocm = isOcmEnabled
    ? ManagedClusterProvider.fromConfig(env.config, {
        logger: env.logger,
      })
    : [];

  if (isOcmEnabled) {
    builder.addEntityProvider(ocm);
  }

  if (isKeycloakEnabled) {
    builder.addEntityProvider(
      KeycloakOrgEntityProvider.fromConfig(env.config, {
        id: 'development',
        logger: env.logger,
        schedule: env.scheduler.createScheduledTaskRunner({
          frequency: { hours: 1 },
          timeout: { minutes: 50 },
          initialDelay: { seconds: 15 },
        }),
      }),
    );
  }

  if (isGithubEnabled) {
    builder.addEntityProvider(
      GithubEntityProvider.fromConfig(env.config, {
        logger: env.logger,
        schedule: env.scheduler.createScheduledTaskRunner({
          frequency: { minutes: 30 },
          timeout: { minutes: 3 },
          initialDelay: { minutes: 1 },
        }),
      }),
    );
  }

  if (isGithubOrgEnabled) {
    const providersConfig = env.config.getOptionalConfig(
      'catalog.providers.githubOrg',
    );

    providersConfig?.keys().forEach(id => {
      const githubOrgConfig = providersConfig?.getConfig(id);

      const githubOrgId = githubOrgConfig.getString('id');
      const githubOrgUrl = githubOrgConfig.getString('orgUrl');

      builder.addEntityProvider(
        GithubOrgEntityProvider.fromConfig(env.config, {
          id: githubOrgId,
          orgUrl: githubOrgUrl,
          logger: env.logger,
          schedule: env.scheduler.createScheduledTaskRunner({
            frequency: { minutes: 60 },
            timeout: { minutes: 15 },
            initialDelay: { seconds: 15 },
          }),
        }),
      );
    });
  }

  if (isGitlabEnabled) {
    builder.addProcessor(new GitlabFillerProcessor(env.config));
  }

  builder.setPlaceholderResolver('openapi', jsonSchemaRefPlaceholderResolver);
  builder.setPlaceholderResolver('asyncapi', jsonSchemaRefPlaceholderResolver);

  builder.addProcessor(new ScaffolderEntitiesProcessor());
  const { processingEngine, router } = await builder.build();
  await processingEngine.start();
  await Promise.all(
    ocm.map(o =>
      env.scheduler.scheduleTask({
        id: `run_ocm_refresh_${o.getProviderName()}`,
        fn: async () => {
          await o.run();
        },
        frequency: { minutes: 30 },
        timeout: { minutes: 10 },
      }),
    ),
  );
  return router;
}

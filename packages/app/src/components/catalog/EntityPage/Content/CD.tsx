import { Grid } from '@material-ui/core';
import { EntityArgoCDHistoryCard } from '@roadiehq/backstage-plugin-argo-cd';
import React from 'react';

export const cdContent = (
  <Grid container spacing={3} justifyContent="space-evenly">
    <Grid item xs={12}>
      <EntityArgoCDHistoryCard />
    </Grid>
  </Grid>
);

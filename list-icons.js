#!/usr/bin/env node

const _ = require('lodash/fp')
const file = process.argv[process.argv.length-1]
const chars = require(file)
const icons = _.flow(
  _.values,
  _.map('levelGraphNodeTypes'),
  _.filter(_.identity),
  _.flatMap(_.values),
  _.map('icon'),
  _.uniq,
  _.filter(_.identity),
  _.sortBy(_.identity),
)(chars)
icons.map(icon => console.log(icon))

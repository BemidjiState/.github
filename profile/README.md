# Helpful tips

To make things a little easier, here is some helpful information for using GitHub in an organization as well as some git in general.

## Collaborators and teams

Compared to an individual GitHub account, working within an organization has some extra features to be aware of when creating repos. When creating a repo, it is private by default. You can also set it to public for the entire world to see. For private repos, you can give access to people within the organization. Here is how to give individuals and even an entire team access to a private repo.

1. From the repo page, go to the *Settings* page.
1. On the sidebar, select *Collaborators and teams*.
1. Use the *Add people* or *Add teams* button.
1. Select the person or team you would like to have access to the repo.
1. When prompted, select the role the person or team should have and use the *Add selection* button to submit your choice.

## Best practice

* Never commit API keys or Personal Authentication Tokens (PAT) in git repositories. Use client side configs instead.
* Commits should be small and frequent.
* Consider using [Conventional Commits](https://www.conventionalcommits.org) specification for human and machine readable commit message.
